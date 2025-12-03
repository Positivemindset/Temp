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
