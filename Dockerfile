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






name: Pact Contract Testing

on:
  push:
    branches: [pact-testing]
  workflow_dispatch:

permissions:
  contents: read
  actions: read
  pull-requests: read
  id-token: write               # Needed for JFrog OIDC

concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

defaults:
  run:
    shell: bash

env:
  CACHE_SOURCE_BRANCH: develop
  NODE_VERSION: 22

jobs:

  # -------------------------------------------------------
  # JOB 1 — Build Node Modules (PRIVATE RUNNER ONLY)
  # -------------------------------------------------------
  produce-node-modules-linux:
    name: Produce Node Modules (Private Runner)
    runs-on: [self-hosted, actions-runner-docker-set]

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          filter: tree:0

      # ---------------------------------------------------
      # JFROG OIDC AUTH
      # ---------------------------------------------------
      - name: Setup JFrog CLI (OIDC)
        id: jfrog-oidc
        uses: jfrog/setup-jfrog-cli@v4
        with:
          jf_url: "https://onesdlc.jfrog.io"
        env:
          oidc-provider-name: "dtp"
          oidc-audience: "dtp-test"

      # ---------------------------------------------------
      # Configure npm to use JFrog registry
      # ---------------------------------------------------
      - name: Configure npm for JFrog
        run: |
          echo "registry=https://onesdlc.jfrog.io/artifactory/api/npm/npm-virtual/" > ~/.npmrc
          echo "//onesdlc.jfrog.io/artifactory/api/npm/npm-virtual/:_authToken=${OIDC_TOKEN}" >> ~/.npmrc
        env:
          OIDC_TOKEN: ${{ steps.jfrog-oidc.outputs.oidc-token }}

      # ---------------------------------------------------
      # BUILD PREP + CACHE LOGIC
      # ---------------------------------------------------
      - name: Set should use cache flag
        id: decide_cache
        uses: ./.github/actions/preparing-variables/set-should-use-cache-var
        with:
          cache-source-branch: ${{ env.CACHE_SOURCE_BRANCH }}

      - name: Build prep
        uses: ./.github/actions/build-prep
        with:
          should-extract-cache: ${{ steps.decide_cache.outputs.should_extract_cache }}
        env:
          NPMRC_B64: ${{ secrets.NPMRC_B64 }}

      # ---------------------------------------------------
      # Install Dependencies Through JFrog
      # ---------------------------------------------------
      - name: Install Dependencies
        run: npm install --verbose

      # ---------------------------------------------------
      # Upload node_modules artifact
      # ---------------------------------------------------
      - name: Upload node_modules
        uses: ./.github/actions/artifacts/node-modules/publish
        with:
          node-version: ${{ env.NODE_VERSION }}


  # -------------------------------------------------------
  # JOB 2 — Contract Tests
  # -------------------------------------------------------
  contract-tests:
    name: Contract Tests
    runs-on: [self-hosted, actions-runner-docker-set]
    needs: produce-node-modules-linux

    env:
      CACHE_SOURCE_BRANCH: pact-testing

    steps:

      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          filter: tree:0

      # ---------------------------------------------------
      # Download dependencies BEFORE Nx + build prep
      # ---------------------------------------------------
      - name: Download node_modules
        uses: ./.github/actions/artifacts/node-modules/download
        with:
          node-version: ${{ env.NODE_VERSION }}

      # ---------------------------------------------------
      # Nx SHAs
      # ---------------------------------------------------
      - name: Derive SHAs for nx affected
        uses: ./.github/3rd-party/set-sha-nx

      # ---------------------------------------------------
      # Build prep again
      # ---------------------------------------------------
      - name: Build prep
        uses: ./.github/actions/build-prep
        with:
          node-version: ${{ env.NODE_VERSION }}
          should-extract-cache: true
          should-use-run-id: false
        env:
          NPMRC_B64: ${{ secrets.NPMRC_B64 }}

      # ---------------------------------------------------
      # Run pact tests
      # ---------------------------------------------------
      - name: Run pact tests
        uses: ./.github/actions/pact-tests/all
        with:
          head-sha: ${{ env.NX_HEAD }}
          base-sha: ${{ env.NX_BASE }}


      # ---------------------------------------------------
      # JWT / IAP LOGIC
      # ---------------------------------------------------
      - name: Check PACT SA exists
        run: |
          if [ -z "${{ secrets.PACT_SA_B64 }}" ]; then
            echo "Missing PACT_SA_B64 secret"; exit 1;
          fi

      - name: Setup Python
        uses: actions/setup-python@v4
        with:
          python-version: "3.11"

      - name: Install Python deps
        run: pip install pyjwt cryptography google-auth requests

      - name: Decode SA
        run: |
          echo "${{ secrets.PACT_SA_B64 }}" | base64 --decode > sa.json

      - name: Validate SA JSON
        run: python3 -c "import json; json.load(open('sa.json')); print('Valid JSON')"

      - name: Generate JWT Token
        id: jwt
        run: |
          TOKEN=$(python3 token-gen/generate_jwt.py)
          echo "TOKEN=$TOKEN" >> $GITHUB_ENV

      - name: Create Zscaler CA file
        run: echo "${{ secrets.ZSCALER_ROOTCA }}" > zscaler.pem

      # ---------------------------------------------------
      # Publish Pact Contracts
      # ---------------------------------------------------
      - name: Publish Pact Contracts
        env:
          SSL_CERT_FILE: zscaler.pem
        run: |
          echo "Publishing Pact contracts..."
          npx pact-broker publish ./pacts \
            --broker-base-url https://digital-platform-pactbroker.dev.bupa.co.uk \
            --broker-token $TOKEN \
            --consumer-app-version ${{ github.sha }}








name: Pact Contract Tests
description: Executes pact contract tests for affected services.

inputs:
  head-sha:
    description: 'HEAD commit SHA'
    required: true
  base-sha:
    description: 'BASE commit SHA'
    required: true

runs:
  using: composite
  steps:

    - name: Validate SHAs
      shell: bash
      run: |
        if [ -z "${{ inputs.head-sha }}" ] || [ -z "${{ inputs.base-sha }}" ]; then
          echo "ERROR: Missing NX SHAs"; exit 1;
        fi
        echo "HEAD_SHA=${{ inputs.head-sha }}"
        echo "BASE_SHA=${{ inputs.base-sha }}"

    # Confirm npm registry points to JFrog (critical)
    - name: Validate npm registry
      shell: bash
      run: npm config get registry

    # Run the pact generation for all affected services
    - name: Execute Pact Tests
      shell: bash
      env:
        HEAD_SHA: ${{ inputs.head-sha }}
        BASE_SHA: ${{ inputs.base-sha }}
      run: |
        echo "Running Pact generation:"
        echo "HEAD_SHA=$HEAD_SHA"
        echo "BASE_SHA=$BASE_SHA"

        npm run generate:pacts -- \
          --all \
          --head="$HEAD_SHA" \
          --base="$BASE_SHA"

        echo "Pact tests completed successfully."
