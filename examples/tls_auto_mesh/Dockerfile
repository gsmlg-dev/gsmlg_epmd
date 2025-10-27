FROM erlang:27-alpine

# Install Elixir for Mix dependencies
RUN apk add --no-cache elixir git && \
    mix archive.install github hexpm/hex branch latest --force && \
    mix local.rebar --force

WORKDIR /build

# Copy example app files
COPY examples/tls_auto_mesh/rebar.config examples/tls_auto_mesh/rebar.lock* ./
COPY examples/tls_auto_mesh/src ./src
COPY examples/tls_auto_mesh/config ./config

# Create _checkouts directory and copy gsmlg_epmd library
RUN mkdir -p _checkouts/gsmlg_epmd
COPY src /build/_checkouts/gsmlg_epmd/src
COPY rebar.config /build/_checkouts/gsmlg_epmd/rebar.config

# Compile gsmlg_epmd first (with dependencies)
RUN cd _checkouts/gsmlg_epmd && rebar3 compile && cd /build

# Build release
RUN rebar3 release

# Runtime stage
FROM erlang:27-alpine

WORKDIR /app

# Copy the release
COPY --from=0 /build/_build/default/rel/gsmlg_epmd_test ./

# Certificates will be mounted at runtime
VOLUME /app/certs

# TLS port for EPMD
EXPOSE 4369

# Erlang distribution port
EXPOSE 8001

# Start in foreground
CMD ["./bin/gsmlg_epmd_test", "foreground"]
