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
