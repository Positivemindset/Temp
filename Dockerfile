# ---- Minimal Hugo Extended runtime on Alpine ----
FROM alpine:3.20

ARG HUGO_VERSION=0.151.1
ARG BASE_URL="http://localhost/"

ENV HUGO_VERSION=${HUGO_VERSION}
ENV BASE_URL=${BASE_URL}
ENV PORT=8080

# Install deps + Hugo (extended)
RUN apk add --no-cache wget tar libc6-compat \
 && wget -q https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-amd64.tar.gz \
 && tar -xzf hugo_extended_${HUGO_VERSION}_linux-amd64.tar.gz \
 && mv hugo /usr/local/bin/hugo \
 && chmod +x /usr/local/bin/hugo \
 && rm -f hugo_extended_${HUGO_VERSION}_linux-amd64.tar.gz

# The workflow will preassemble the site/ directory
WORKDIR /site
COPY site/ ./

EXPOSE 8080

# Run Hugo dev server; Cloud Run injects $PORT
CMD ["sh","-c","hugo server -D --bind 0.0.0.0 --port ${PORT} --baseURL ${BASE_URL} --appendPort=false"]




jobs:
  download-deps:
    runs-on: self-hosted

    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v3
        with:
          node-version: 18

      - name: JFrog npm install
        run: jf npm install

      - name: Create node_modules archive
        run: tar -czf node_modules.tar.gz node_modules


      - name: Upload to GCS cache bucket
        run: |
          gsutil cp node_modules.tar.gz gs://${{ secrets.CACHE_BUCKET }}/node/node_modules.tar.gz

      - name: Upload artifact for next job
        uses: actions/upload-artifact@v4
        with:
          name: node-cache
          path: node_modules.tar.gz



trigger-contract-tests:
  needs: download-deps
  runs-on: ubuntu-latest

  permissions:
    id-token: write
    contents: read

  steps:
    - uses: actions/checkout@v4

    - name: Authenticate to GCP (WIF)
      uses: google-github-actions/auth@v2
      with:
        token_format: access_token
        workload_identity_provider: ${{ secrets.WIF_PROVIDER }}
        service_account: ${{ secrets.WIF_SA }}

    - name: Submit Cloud Build Job
      run: |
        gcloud builds submit \
          --config=cloudbuild/contract-tests.yaml \
          --region=europe-west1 \
          --worker-pool="projects/${{ secrets.GCP_PROJECT }}/locations/europe-west1/workerPools/${{ secrets.WORKER_POOL }}" \
          --gcs-source-staging-dir=gs://${{ secrets.STAGING_BUCKET }}/cb-source \
          --substitutions=_CACHE_BUCKET="${{ secrets.CACHE_BUCKET }}",_BACKEND_ID="${{ secrets.BACKEND_ID }}"



steps:
  - name: "gcr.io/google.com/cloudsdktool/cloud-sdk"
    entrypoint: bash
    args:
      - "-c"
      - |
        echo "Downloading cached node_modules..."
        gsutil cp gs://$_CACHE_BUCKET/node/node_modules.tar.gz .
        tar -xzf node_modules.tar.gz

        echo "Running contract tests..."
        npm test:contract

        echo "Generating IAP JWT..."
        TOKEN=$(gcloud auth print-identity-token \
          --audiences="/projects/$PROJECT_ID/global/backendServices/$_BACKEND_ID")

        echo "Publishing Pact files..."
        for pact in $(find pacts -name '*.json'); do
          consumer=$(jq -r '.consumer.name' $pact)
          provider=$(jq -r '.provider.name' $pact)
          curl -X PUT \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            --data @"$pact" \
            "https://digital-platform-pactbroker.dev.bupa.co.uk/pacts/provider/$provider/consumer/$consumer/version/$BUILD_ID"
        done

options:
  pool:
    name: "projects/$PROJECT_ID/locations/europe-west1/workerPools/$WORKER_POOL"

substitutions:
  _CACHE_BUCKET: ""
  _BACKEND_ID: ""


name: K6 Performance Suite

on:
  workflow_dispatch:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  run-k6-tests:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Install dependencies
        run: yarn install --frozen-lockfile

      - name: Setup k6
        uses: grafana/setup-k6-action@v1
        with:
          version: latest

      - name: Build TypeScript
        run: yarn build

      - name: Run K6 Tests
        run: |
          mkdir -p reports

          echo "🔹 Running API smoke test"
          yarn test:api:smoke \
            --out json=reports/api-smoke.json \
            --summary-export=reports/api-smoke-summary.json || true

          echo "🔹 Running API load test"
          yarn test:api:load \
            --out json=reports/api-load.json \
            --summary-export=reports/api-load-summary.json || true

          echo "🔹 Running API stress test"
          yarn test:api:stress \
            --out json=reports/api-stress.json \
            --summary-export=reports/api-stress-summary.json || true

          echo "🔹 Running UI load test"
          yarn test:ui:load \
            --out json=reports/ui-load.json \
            --summary-export=reports/ui-load-summary.json || true

          echo "🔹 Running Auth test"
          yarn test:api:auth \
            --out json=reports/api-auth.json \
            --summary-export=reports/api-auth-summary.json || true

          echo "🔹 Running REST test"
          yarn test:api:rest \
            --out json=reports/api-rest.json \
            --summary-export=reports/api-rest-summary.json || true

          echo "🔹 Running UI pages test"
          yarn test:ui:pages \
            --out json=reports/ui-# This block establishes the connection to Terraform Cloud (TFE) 
# and ensures all 4 load balancers are managed in ONE single state file.
terraform {
  cloud {
    organization = "BGUK"
    hostname     = "optimus.bupa.com"

    workspaces {
      # This is the single workspace that tracks all production 
      # and non-production load balancer resources.
      name = "bguk-shared-vpc-prod" 
    }
  }

  required_version = ">= 1.9.8"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0"
    }
  }
}

# The provider block configures the project and region for GCP.
provider "google" {
  project = var.project_id
  region  = var.region
}





            
            --summary-export=reports/ui-pages-summary.json || true

      - name: Upload K6 Reports
        uses: actions/upload-artifact@v4
        with:
          name: k6-performance-
          




