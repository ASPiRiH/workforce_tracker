FROM erlang:26-alpine AS builder
WORKDIR /build
COPY rebar.config rebar.lock* ./
RUN rebar3 get-deps
COPY . .
RUN rebar3 as prod release

FROM alpine:3.19
RUN apk add --no-cache libstdc++ openssl ncurses-libs bash
WORKDIR /app
COPY --from=builder /build/_build/prod/rel/workforce_tracker ./
ENTRYPOINT ["/app/bin/workforce_tracker", "foreground"]
