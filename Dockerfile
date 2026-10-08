# syntax=docker/dockerfile:1
# All three tools: tessera-shard, tessera-dpixel, tessera-zarr-upload.
# Also the source for the Apptainer image (see README).
FROM ocaml/opam:debian-13-ocaml-5.3 AS build
RUN sudo ln -sf /usr/bin/opam-2.5 /usr/bin/opam && opam init --reinit -ni
RUN sudo rm -f /etc/apt/apt.conf.d/docker-clean; echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' | sudo tee /etc/apt/apt.conf.d/keep-cache
RUN sudo apt update && sudo apt-get --no-install-recommends install -y \
    libcurl4-openssl-dev \
    libffi-dev \
    libgmp-dev \
    libgdal-dev \
    libblosc-dev \
    pkg-config \
    m4 \
    curl
# The OCaml bindings (gdal, stac_client, npy, zarr, zarr-s3, s3,
# tessera-grid) and conf-gdal come from the tunbury overlay, pinned there by
# commit; it is the repository day10 builds against too, so the image and the
# local build see the same versions. The overlay is added with higher
# priority than the default repository: upstream has an unrelated `zarr`.
RUN opam repo add --rank 1 tunbury https://github.com/tunbury/opam-repository-overlay.git && \
    opam update && \
    opam install -y stac_client gdal npy yojson cmdliner \
                    zarr zarr-blosc zarr-s3 s3 eio eio_main tessera-grid
WORKDIR /src
COPY --chown=opam --link dune-project dune-workspace ./
COPY --chown=opam --link lib/ lib/
COPY --chown=opam --link bin/dune bin/tessera_dpixel.ml bin/tessera_shard.ml bin/tessera_zarr_upload.ml bin/
RUN opam exec -- dune build bin/tessera_dpixel.exe bin/tessera_shard.exe bin/tessera_zarr_upload.exe

FROM debian:13
RUN rm -f /etc/apt/apt.conf.d/docker-clean; echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
# libgdal is dlopen'ed by name, hence the unversioned symlink.
RUN apt update && apt-get --no-install-recommends install -y \
    ca-certificates \
    curl \
    libgdal36 \
    libblosc1 \
    libzstd1 \
    libcurl4 \
    libffi8 && \
    ln -s /usr/lib/x86_64-linux-gnu/libgdal.so.36 /usr/lib/x86_64-linux-gnu/libgdal.so
COPY --from=build --link /src/_build/default/bin/tessera_dpixel.exe /usr/local/bin/tessera-dpixel
COPY --from=build --link /src/_build/default/bin/tessera_shard.exe /usr/local/bin/tessera-shard
COPY --from=build --link /src/_build/default/bin/tessera_zarr_upload.exe /usr/local/bin/tessera-zarr-upload
# No entrypoint: name the tool, e.g. `docker run … tessera-tools tessera-dpixel --help`.
CMD ["sh", "-c", "echo 'tools: tessera-shard tessera-dpixel tessera-zarr-upload'; echo; tessera-shard --help | head -20"]
