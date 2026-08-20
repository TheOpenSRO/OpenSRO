# Multi-stage build: compile the gateway server binary, then ship it in a
# minimal runtime image. No game data (pk2/refdata) is baked in -- this
# project is BYO-data throughout (see docs/LEGAL.md), so the image is just
# the server binary plus CA certs (needed for TLS if -tls-cert/-tls-key
# aren't self-signed, and generally good practice regardless).

FROM golang:1.25-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/srrevamp-server ./cmd/server
RUN CGO_ENABLED=0 go build -o /out/import-refdata ./cmd/import-refdata

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/srrevamp-server /usr/local/bin/srrevamp-server
COPY --from=build /out/import-refdata /usr/local/bin/import-refdata
EXPOSE 15779
ENTRYPOINT ["/usr/local/bin/srrevamp-server"]
