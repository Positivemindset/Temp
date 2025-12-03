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
  id-token: write

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

  # --------------------------------------------------------------------------
  # 1. BUILD NODE MODULES (for caching + reuse)
  # --------------------------------------------------------------------------
  produce-node-modules-linux:
    name: Produce Node Modules (Linux)
    runs-on: [actions-runner-docker-set]

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          filter: tree:0

      - name: Set “should use cache” flag
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

      # ----------------------------
      # JFROG AUTH + YARN INSTALL
      # ----------------------------
      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: ${{ env.NODE_VERSION }}

      - name: Setup JFrog CLI (OIDC)
        id: jfrog-oidc
        uses: jfrog/setup-jfrog-cli@v4
        env:
          JF_URL: 'https://onesdlc.jfrog.io'
        with:
          oidc-provider-name: 'dtp'
          oidc-audience: 'dtp-test'

      - name: Configure npm to use JFrog registry
        run: |
          echo "Configuring npm registry through JFrog..."
          jf npm-config --global --repo npm-virtual
          npm config list

      - name: Install Yarn via JFrog
        run: npm install -g yarn

      # ----------------------------
      # Upload node_modules for reuse
      # ----------------------------
      - name: Upload node_modules as artifact
        uses: ./.github/actions/artifacts/node-modules/publish
        with:
          node-version: ${{ env.NODE_VERSION }}

  # --------------------------------------------------------------------------
  # 2. CONTRACT TESTS
  # --------------------------------------------------------------------------
  contract-tests:
    name: Contract Tests
    runs-on: [actions-runner-docker-set]
    needs: produce-node-modules-linux

    env:
      CACHE_SOURCE_BRANCH: pact-testing

    steps:

      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          filter: tree:0

      - name: Derive SHAs for nx
        uses: ./.github/3rd-party/set-sha-nx

      - name: Build prep
        uses: ./.github/actions/build-prep
        with:
          node-version: ${{ env.NODE_VERSION }}
          should-extract-cache: true
          should-use-run-id: false
        env:
          NPMRC_B64: ${{ secrets.NPMRC_B64 }}

      # ----------------------------
      # JFROG AUTH + YARN
      # ----------------------------
      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: ${{ env.NODE_VERSION }}

      - name: Setup JFrog CLI (OIDC)
        id: jfrog-oidc
        uses: jfrog/setup-jfrog-cli@v4
        env:
          JF_URL: 'https://onesdlc.jfrog.io'
        with:
          oidc-provider-name: 'dtp'
          oidc-audience: 'dtp-test'

      - name: Configure npm for JFrog
        run: |
          jf npm-config --global --repo npm-virtual

      - name: Install Yarn through JFrog
        run: npm install -g yarn

      # ----------------------------
      # Run Contract Tests
      # ----------------------------
      - name: Run contract tests
        uses: ./.github/actions/pact-tests/all
        with:
          head-sha: ${{ env.NX_HEAD }}
          base-sha: ${{ env.NX_BASE }}

      # --------------------------------------------------------------
      # JWT GENERATION FOR PACT-BROKER (Cloud Run IAP)
      # --------------------------------------------------------------
      - name: Verify PACT SA secret exists
        run: |
          if [ -z "${{ secrets.PACT_SA_B64 }}" ]; then
            echo "Missing PACT_SA_B64 secret"
            exit 1
          fi

      - name: Setup Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.11'

      - name: Install Python dependencies
        run: |
          pip install pyjwt cryptography google-auth requests

      - name: Create service account file
        run: |
          echo -n "${{ secrets.PACT_SA_B64 }}" | base64 --decode > sa.json

      - name: Validate SA JSON
        run: |
          python3 - <<'EOF'
import json
json.load(open('sa.json'))
print("Valid JSON")
EOF

      - name: Generate JWT token
        id: jwt
        run: |
          TOKEN=$(python3 token-gen/generate_jwt.py)
          echo "TOKEN=$TOKEN" >> $GITHUB_ENV

      - name: Create SSL cert file
        run: |
          echo "${{ secrets.ZSCALER_ROOTCA }}" > zscaler.pem

      # --------------------------------------------------------------
      # Publish Pact Contracts → Pact Broker
      # --------------------------------------------------------------
      - name: Publish Pact results to Pact Broker
        run: |
          echo "Publishing Pact contracts to Pact Broker…"
          npx pact-broker publish ./pacts \
            --broker-base-url https://digital-platform-pactbroker.dev.bupa.co.uk \
            --consumer-app-version ${{ github.sha }} \
            --broker-token $TOKEN

