FROM alpine:3.20 AS build

ARG ZIG_VERSION=0.15.1

RUN apk add --no-cache bash build-base curl git xz

RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1

WORKDIR /src
COPY . .

RUN /opt/zig/zig build -Doptimize=ReleaseSafe
RUN mkdir -p /out/public/git
RUN sh ./scripts/create-fixture-repos.sh /out/public/git ./fixtures
RUN cp zig-out/bin/packbase /out/packbase

FROM alpine:3.20

RUN apk add --no-cache ca-certificates git

COPY --from=build /out/packbase /usr/local/bin/packbase
COPY --from=build /out/public /var/lib/packbase/public

ENV PACKBASE_ROOT=/var/lib/packbase/public
ENV PACKBASE_PORT=8080

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/packbase"]
