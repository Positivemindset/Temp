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




# ---------------------------------------------------------
# BUILD PREP WITH CACHING (REAL FIX)
# ---------------------------------------------------------

- name: Restore node_modules cache
  uses: actions/cache@v3
  with:
    path: |
      node_modules
      */*/node_modules
      */*/*/node_modules
    key: node-modules-${{ runner.os }}-${{ hashFiles('**/yarn.lock') }}
    restore-keys: |
      node-modules-${{ runner.os }}-

- name: Build prep
  uses: ./.github/actions/build-prep
  with:
    should-extract-cache: ${{ steps.decide_cache.outputs.should_extract_cache }}
  env:
    NPMRC_B64: ${{ secrets.NPMRC_B64 }}

- name: Install Yarn dependencies
  run: yarn install --frozen-lockfile


