name: Report merged branches not deleted (org-wide)

on:
  schedule:
    - cron: "30 7 * * *"   # Daily 07:30 UTC
  workflow_dispatch: {}     # Manual run with no inputs

concurrency:
  group: report-merged-branches-not-deleted
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: read
  actions: read

jobs:
  scan:
    name: Scan org PRs and report stale branches
    runs-on: ubuntu-latest
    timeout-minutes: 60

    env:
      # --- SET THESE ONCE ---
      # Prefer setting ORG_LOGIN as an Actions variable at repo/org level.
      # Settings → Actions → Variables → ORG_LOGIN = your GitHub org login
      ORG: ${{ vars.ORG_LOGIN != '' && vars.ORG_LOGIN || 'your-org' }}

      # Default behaviour (no prompts)
      INCLUDE_PRIVATE: "true"
      INCLUDE_ARCHIVED: "false"
      LOOKBACK_DAYS: "90"         # how far back to scan merged PRs
      GRACE_DAYS: "3"             # only flag branches merged >= this many days ago
      BRANCH_EXCLUDES: "renovate/**,dependabot/**"

      # Optional long-term archival (commit reports into a repo); off by default
      ENABLE_GIT_ARCHIVE: "false"
      ARCHIVE_REPO: your-org/ops-reports
      ARCHIVE_BRANCH: reports
      ARCHIVE_PATH: reports/merged-branches-not-deleted

    steps:
      - name: Create installation token (GitHub App)
        id: app-token
        uses: actions/create-github-app-token@v1
        with:
          app-id: ${{ secrets.ORG_APP_ID }}
          private-key: ${{ secrets.ORG_APP_PRIVATE_KEY }}
          owner: ${{ env.ORG }}

      - name: Tooling check & auth
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
        run: |
          set -euo pipefail
          command -v gh >/dev/null || (echo "gh not found" && exit 1)
          command -v jq >/dev/null || (echo "jq not found" && exit 1)
          command -v git >/dev/null || (echo "git not found" && exit 1)
          [[ -n "${GH_TOKEN}" ]] || (echo "GH_TOKEN missing" && exit 1)
          gh auth status

      - name: Enumerate repos and find merged-but-not-deleted branches
        id: scan
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          ORG: ${{ env.ORG }}
          INCLUDE_PRIVATE: ${{ env.INCLUDE_PRIVATE }}
          INCLUDE_ARCHIVED: ${{ env.INCLUDE_ARCHIVED }}
          LOOKBACK_DAYS: ${{ env.LOOKBACK_DAYS }}
          GRACE_DAYS: ${{ env.GRACE_DAYS }}
          BRANCH_EXCLUDES: ${{ env.BRANCH_EXCLUDES }}
        run: |
          set -euo pipefail

          retry() { local m="$1"; shift; local s="$1"; shift; local n=0;
            until "$@"; do n=$((n+1)); [[ $n -ge $m ]] && return 1; echo "Retry $n/$m..."; sleep "$s"; done; }
          rate_guard() {
            local r=$(gh api /rate_limit -q '.resources.core.remaining' || echo 0)
            local t=$(gh api /rate_limit -q '.resources.core.reset' || echo 0)
            if [[ "${r:-0}" -lt 50 ]]; then local now=$(date +%s); local wait=$((t - now + 5));
              [[ $wait -gt 0 ]] && echo "Rate limit low ($r). Sleeping ${wait}s..." && sleep "$wait"; fi; }

          [[ "$INCLUDE_PRIVATE" == "true" ]] && VIS="" || VIS="--public"

          echo "Listing repos for org: $ORG"
          rate_guard
          retry 3 3 gh repo list "$ORG" --limit 1000 $VIS \
            --json name,isArchived,defaultBranchRef > /tmp/repos.json

          # Filter → TSV: name<TAB>defaultBranch
          jq -c '.[]' /tmp/repos.json | while read -r row; do
            is_arch=$(jq -r '.isArchived' <<<"$row")
            name=$(jq -r '.name' <<<"$row")
            defbr=$(jq -r '.defaultBranchRef.name // empty' <<<"$row")
            [[ "$INCLUDE_ARCHIVED" == "false" && "$is_arch" == "true" ]] && continue
            [[ -z "$defbr" ]] && continue
            printf "%s\t%s\n" "$name" "$defbr"
          done > /tmp/repos_filtered.tsv

          OUT_CSV="/tmp/merged_branches_not_deleted.csv"
          OUT_MD="/tmp/merged_branches_not_deleted.md"
          NOW_UTC="$(date -u +"%Y-%m-%d %H:%M UTC")"
          CUTOFF_LOOKBACK="$(date -u -d "${LOOKBACK_DAYS} days ago" +"%Y-%m-%dT%H:%M:%SZ")"
          CUTOFF_GRACE="$(date -u -d "${GRACE_DAYS} days ago" +"%Y-%m-%dT%H:%M:%SZ")"

          echo "org,repo,default_branch,pr_number,branch,merged_at,author,head_sha" > "$OUT_CSV"
          {
            echo "# Merged branches not deleted"
            echo
            echo "_Org: $ORG — Generated on $NOW_UTC_"
            echo "_Lookback: ${LOOKBACK_DAYS}d; Grace after merge: ${GRACE_DAYS}d_"
            echo
            echo "| Repo | PR # | Branch | Merged At (UTC) | Author | Head SHA |"
            echo "|------|------|--------|------------------|--------|----------|"
          } > "$OUT_MD"

          FOUND=0

          while IFS=$'\t' read -r REPO DEFBR; do
            rate_guard
            if [[ "$LOOKBACK_DAYS" == "0" ]]; then
              PRS=$(retry 3 3 gh api --paginate "/repos/$ORG/$REPO/pulls?state=closed&base=${DEFBR}&per_page=100" \
                    | jq -s 'add | map(select(.merged_at != null))')
            else
              PRS=$(retry 3 3 gh api --paginate "/repos/$ORG/$REPO/pulls?state=closed&base=${DEFBR}&per_page=100" \
                    | jq -s --arg cutoff "$CUTOFF_LOOKBACK" 'add | map(select(.merged_at != null and .merged_at >= $cutoff))')
            fi
            [[ "$(jq 'length' <<<"$PRS")" -eq 0 ]] && continue

            jq -c '.[]' <<<"$PRS" | while read -r PR; do
              PR_NUM=$(jq -r '.number' <<<"$PR")
              BRANCH=$(jq -r '.head.ref' <<<"$PR")
              HEAD_OWNER=$(jq -r '.head.repo.owner.login // empty' <<<"$PR")
              MERGED_AT=$(jq -r '.merged_at' <<<"$PR")
              AUTHOR=$(jq -r '.user.login' <<<"$PR")
              HEAD_SHA=$(jq -r '.head.sha' <<<"$PR")

              [[ "$HEAD_OWNER" != "$ORG" || -z "$BRANCH" ]] && continue
              [[ "$MERGED_AT" < "$CUTOFF_GRACE" ]] || continue

              # Exclude patterns (globs)
              IGNORE=0; IFS=',' read -r -a EXCLUDES <<<"$BRANCH_EXCLUDES"
              for pat in "${EXCLUDES[@]}"; do
                pat="$(echo "$pat" | xargs)"; [[ -z "$pat" ]] && continue
                if [[ "$BRANCH" == $pat ]]; then IGNORE=1; break; fi
              done
              [[ $IGNORE -eq 1 ]] && continue

              if retry 2 2 gh api -H "Accept: application/vnd.github+json" "/repos/$ORG/$REPO/git/ref/heads/${BRANCH}" >/dev/null 2>&1; then
                echo "$ORG,$REPO,$DEFBR,$PR_NUM,$BRANCH,$MERGED_AT,$AUTHOR,$HEAD_SHA" >> "$OUT_CSV"
                printf "| %s | %s | \`%s\` | %s | %s | \`%s\` |\n" "$REPO" "$PR_NUM" "$BRANCH" "$MERGED_AT" "$AUTHOR" "$HEAD_SHA" >> "$OUT_MD"
                FOUND=$((FOUND+1))
              fi
            done
          done < /tmp/repos_filtered.tsv

          {
            echo
            if [[ "$FOUND" -eq 0 ]]; then
              echo "> ✅ No merged-but-not-deleted branches found under current filters."
            else
              echo "> ⚠️ Found $FOUND merged-but-not-deleted branch(es)."
            fi
          } >> "$OUT_MD"

          echo "found=$FOUND" >> $GITHUB_OUTPUT

          {
            echo "## Merged branches not deleted"
            echo "**Org:** $ORG  "
            echo "**Lookback:** ${LOOKBACK_DAYS} days  "
            echo "**Grace after merge:** ${GRACE_DAYS} days  "
            echo "**Found:** $FOUND"
            echo
            cat "$OUT_MD"
          } >> "$GITHUB_STEP_SUMMARY"

      - name: Upload report artifact
        uses: actions/upload-artifact@v4
        with:
          name: merged-branches-not-deleted-${{ env.ORG }}-${{ github.run_id }}
          path: |
            /tmp/merged_branches_not_deleted.csv
            /tmp/merged_branches_not_deleted.md
          if-no-files-found: warn
          retention-days: 90

      - name: Commit report to archive branch (optional)
        if: env.ENABLE_GIT_ARCHIVE == 'true'
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          ORG: ${{ env.ORG }}
          ARCHIVE_REPO: ${{ env.ARCHIVE_REPO }}
          ARCHIVE_BRANCH: ${{ env.ARCHIVE_BRANCH }}
          ARCHIVE_PATH: ${{ env.ARCHIVE_PATH }}
        run: |
          set -euo pipefail
          TMPDIR=$(mktemp -d)
          git config --global user.name "repo-bot"
          git config --global user.email "repo-bot@users.noreply.github.com"
          git clone "https://x-access-token:${GH_TOKEN}@github.com/${ARCHIVE_REPO}.git" "$TMPDIR"
          cd "$TMPDIR"
          git fetch origin "${ARCHIVE_BRANCH}" || true
          git checkout -B "${ARCHIVE_BRANCH}" || git checkout "${ARCHIVE_BRANCH}"

          mkdir -p "${ARCHIVE_PATH}"
          DATE_TAG=$(date -u +%Y-%m-%d)
          cp /tmp/merged_branches_not_deleted.csv "${ARCHIVE_PATH}/merged_${ORG}_${DATE_TAG}.csv"
          cp /tmp/merged_branches_not_deleted.md  "${ARCHIVE_PATH}/merged_${ORG}_${DATE_TAG}.md"
          git add "${ARCHIVE_PATH}"
          git commit -m "chore(report): merged branches not deleted for ${ORG} on ${DATE_TAG} (run ${{ github.run_id }})" || true
          git push origin "${ARCHIVE_BRANCH}"




Terraform Modularisation Strategy — PlatformNetworkLase UK & Global

Author: Harsha Evuri
Date: November 2025
Audience: Platform Engineering / DevOps / Cloud Network Automation

Background

The current Terraform implementation for PlatformNetworkLase provisions several critical networking components — including interconnects, Cloud Armor, external and static load balancers, on-prem VPN connections, and IAM configurations — from a single Terraform state file.

While this approach simplifies deployment, it also introduces risk: a single terraform plan or apply can affect multiple unrelated resources or environments.
This document outlines several modularisation strategies designed to improve isolation, maintainability, and CI/CD safety using Terraform Cloud and GitHub Actions.

Objectives

Achieve environment-level isolation between production and non-production.

Create separate Terraform state files to minimise blast radius.

Retain Terraform Cloud as the backend with per-environment workspaces.

Support existing Bupa Registry modules without modification.

Enable path-based GitHub Actions CI/CD execution for selective deployments.

Maintain full traceability and operational visibility.

Common Design Principles

Each environment (nonprod, prod) maps to a distinct Terraform Cloud workspace.

Each lowest-level folder represents a deployable stack with its own backend and variables.

Shared configuration (e.g. region, org name, labels) is stored in Terraform Cloud variable sets.

GitHub workflows use path-based triggers to ensure only relevant stacks run.

Workspace naming remains consistent across all environments and organisations:

uk-hub-np-euw1-external-lb

global-hub-prd-euw1-interconnect

Option 1 – Per-Component Stack Structure

Granularity: One Terraform state per component × environment × region
Safety: Highest

platform-network-release/
├─ security/
│  ├─ uk/nonprod/europe-west1/cloud-armor/
│  ├─ uk/prod/europe-west1/cloud-armor/
│  ├─ global/nonprod/europe-west1/cloud-armor/
│  └─ global/prod/europe-west1/cloud-armor/
├─ uk/hub/nonprod/europe-west1/
│  ├─ external-lb/
│  ├─ external-lb-static/
│  ├─ interconnect/
│  ├─ onprem-connection/
│  └─ hub-iam/
├─ uk/hub/prod/europe-west1/...
└─ global/hub/(nonprod|prod)/europe-west1/...


Example Workspaces

Org	Env	Region	Component	Workspace
UK	NonProd	ew1	External LB	uk-hub-np-euw1-external-lb
UK	Prod	ew1	External LB	uk-hub-prd-euw1-external-lb
Global	NonProd	ew1	Interconnect	global-hub-np-euw1-interconnect
Global	Prod	ew1	Cloud Armor	global-security-prd-euw1-cloud-armor

Advantages

Each component is independently deployable.

Minimal blast radius during changes.

Enables parallel CI/CD pipelines.

Clear ownership boundaries per service or function.

Disadvantages

Increased number of folders and workspaces.

Requires initial alignment on naming conventions.

Option 2 – Environment and Region Stacks

Granularity: One Terraform state per domain (networking or load balancers) × environment
Safety: Medium

uk/hub/nonprod/europe-west1/
├─ networking/
│  ├─ main.tf
│  ├─ variables.tf
│  └─ terraform.tfvars
└─ loadbalancers/
   ├─ main.tf
   ├─ variables.tf
   ├─ terraform.tfvars
   ├─ rules-nonprod.yaml
   └─ rules-static-nonprod.yaml


Workspaces

uk-hub-np-euw1-networking
uk-hub-np-euw1-loadbalancers
uk-hub-prd-euw1-networking
uk-hub-prd-euw1-loadbalancers


Advantages

Fewer state files to manage.

Logical grouping by domain.

Easier for small teams managing multiple components.

Disadvantages

Larger blast radius than Option 1.

Cross-resource dependencies within a plan.

Option 3 – Single State per Environment

Granularity: One Terraform state file per environment
Safety: Low

uk/hub/nonprod/europe-west1/
├─ main.tf
├─ variables.tf
└─ terraform.tfvars


Workspaces

uk-hub-np-euw1
uk-hub-prd-euw1
global-hub-np-euw1
global-hub-prd-euw1


Advantages

Simplest to set up and operate.

Minimal CI/CD configuration.

Disadvantages

A single plan affects all resources.

Difficult rollback or partial deployment.

Not suitable for production workloads.

Option 4 – Security-Central Hybrid

Granularity:

Dedicated Cloud Armor stack per organisation and environment

Separate stacks for load balancers, interconnects, and IAM

security/
 ├─ uk/nonprod/europe-west1/cloud-armor/
 ├─ uk/prod/europe-west1/cloud-armor/
 ├─ global/nonprod/europe-west1/cloud-armor/
 └─ global/prod/europe-west1/cloud-armor/
uk/hub/... (same as Option 1)


Advantages

Dedicated security management boundaries.

Easier audit and compliance traceability.

Independent deployment lifecycle for WAF policies.

Disadvantages

Requires remote-state references between LB and Armor.

Slightly higher CI/CD integration overhead.

Option 5 – Shared Component Folder with Environment tfvars

Granularity: One component folder reused by multiple environments using environment-specific tfvars files.
Safety: Good

uk/hub/europe-west1/external-lb/
├─ main.tf
├─ variables.tf
├─ nonprod.tfvars
└─ prod.tfvars


Workspaces

uk-hub-np-euw1-external-lb
uk-hub-prd-euw1-external-lb


Advantages

Common HCL code for all environments.

Consistent variable definitions.

Reduces code duplication.

Disadvantages

Possible misuse of incorrect tfvars during deployment.

Requires CI enforcement for tfvars mapping.

Option 6 – Per-Environment Component Stacks

Granularity: Dedicated per-component folders for each environment.
Safety: Very High

uk/hub/nonprod/europe-west1/external-lb/
  ├─ main.tf
  ├─ variables.tf
  └─ nonprod.tfvars
uk/hub/prod/europe-west1/external-lb/
  ├─ main.tf
  ├─ variables.tf
  └─ prod.tfvars


Advantages

Clear environment separation.

Easier to manage CI/CD pipelines.

Predictable change control and ownership.

Disadvantages

Slightly higher folder count.

More initial setup effort.

Option 7 – Environment-Aggregated Composition

Granularity: One execution root per environment containing all related .tf files such as load balancer, Cloud Armor, IP address, and on-prem connectivity.
Safety: Moderate to Low

platform-network-release/
├─ .github/workflows/
│  ├─ tf-cicd/action.yml
│  └─ tf-cicd/ext-lb-west1.yml
│
├─ uknethub/
│  ├─ Hub IAM/
│  │  └─ iam.tf
│  └─ external_lb/west1/
│     ├─ cloud-armor.tf
│     ├─ load-balancer.tf
│     ├─ on-prem-connection.tf
│     ├─ provider.tf
│     ├─ variables.tf
│     ├─ terraform.tfvars
│     ├─ tfvars/
│     │  ├─ common-np.tfvars
│     │  └─ uki-np.tfvars
│     └─ README.md


Concept

All resources for an environment are managed from a single folder.

Multiple tfvars merge via locals into unified maps.

Each workspace represents one environment–region combination.

Advantages

Compact, easier structure.

Simplifies transition from single-state design.

Manages interdependent components in one plan.

Disadvantages

Larger blast radius.

Harder rollback.

Limited ownership separation.

Complex dependency management.

Recommended Use

Transitional model during migration from single-state to modular design.

Out of Scope for this Phase

The following options are excluded from the current implementation but may be revisited later:

Terragrunt-based orchestration – Suitable for dependency-aware automation, but adds tooling complexity.

Stacks catalog-driven CI (stacks.yaml) – Recommended for large-scale CI orchestration, deferred until modular foundations are stable.
