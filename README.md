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
Comparative Summary
Option	Folder Count	Workspace Count	State Scope	Blast Radius	Setup Effort	Recommended Use
1 – Per-Component Stack Structure	High	High	Per component/env	Minimal	Medium	Production
2 – Environment and Region Stacks	Medium	Medium	Domain-wide	Moderate	Low	Simplified nonprod
3 – Single State per Environment	Low	Low	Whole env	Large	Very Low	Testing only
4 – Security-Central Hybrid	High	High	Component + security	Minimal	Medium	Enterprise security
5 – Shared Component Folder with Environment tfvars	Medium	High	Per component/env	Small	Low	Nonprod/POC
6 – Per-Environment Component Stacks	High	High	Per component/env	Minimal	Medium	Balanced setup
7 – Environment-Aggregated Composition	Low	Low	Per env-region	High	Low	Transitional model
Recommendations
Area	Recommended Option	Rationale
Production	Option 1 + Option 4	Strong isolation and separate security lifecycle
Non-Production	Option 6 or Option 5	Lightweight, flexible, and easy to iterate
Transition Phase	Option 7	Gradual migration path from monolithic state
Security	Dedicated Cloud Armor stacks	Independent policy lifecycle and audit control
Next Steps
Agree on preferred option with platform and security leads.
Create Terraform Cloud workspaces per environment and component.
Migrate existing state files using terraform import where required.
Configure GitHub workflow path filters to isolate deployments.
Apply workspace protection and approval for production.
Document naming conventions, variables, and CI/CD rules.
End of Document
