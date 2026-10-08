# syntax=docker/dockerfile:1
# tessera-dpixel: download tool only. tessera-shard and tessera-zarr-upload
# (zarr, s3) are not built here.
FROM ocaml/opam:debian-13-ocaml-5.3 AS build
RUN sudo ln -sf /usr/bin/opam-2.5 /usr/bin/opam && opam init --reinit -ni
RUN sudo rm -f /etc/apt/apt.conf.d/docker-clean; echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' | sudo tee /etc/apt/apt.conf.d/keep-cache
RUN sudo apt update && sudo apt-get --no-install-recommends install -y \
    libcurl4-openssl-dev \
    libffi-dev \
    libgmp-dev \
    libgdal-dev \
    pkg-config \
    m4 \
    curl
# The OCaml bindings (gdal, stac_client, npy) and conf-gdal come from the
# tunbury overlay, pinned there by commit; it is the repository day10 builds
# against too, so the image and the local build see the same versions.
RUN opam repo add tunbury https://github.com/tunbury/opam-repository-overlay.git && \
    opam update && \
    opam install -y stac_client gdal npy yojson cmdliner
WORKDIR /src
COPY --chown=opam --link dune-project dune-workspace ./
COPY --chown=opam --link lib/ lib/
COPY --chown=opam --link bin/tessera_dpixel.ml bin/
# Only the dpixel stanza: the repo's bin/dune also declares tessera-shard and
# the Zarr uploader, whose dependencies this image does not install.
RUN echo '(executable (name tessera_dpixel) (modules tessera_dpixel) (libraries tessera_common stac_client gdal npy yojson unix bigarray cmdliner))' > bin/dune
RUN opam exec -- dune build bin/tessera_dpixel.exe

FROM debian:13
RUN rm -f /etc/apt/apt.conf.d/docker-clean; echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
# libgdal is dlopen'ed by name, hence the unversioned symlink.
RUN apt update && apt-get --no-install-recommends install -y \
    ca-certificates \
    curl \
    libgdal36 \
    libcurl4 \
    libffi8 && \
    ln -s /usr/lib/x86_64-linux-gnu/libgdal.so.36 /usr/lib/x86_64-linux-gnu/libgdal.so
COPY --from=build --link /src/_build/default/bin/tessera_dpixel.exe /usr/local/bin/tessera-dpixel
ENTRYPOINT ["/usr/local/bin/tessera-dpixel"]
