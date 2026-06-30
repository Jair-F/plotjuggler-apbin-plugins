# syntax=docker/dockerfile:1
FROM autoantwort/qt5-cross-compiled-windows-build-env:latest AS builder

ARG PJ_TAG=3.9.2
ARG MXE_TARGET_ARCH=x86_64
ARG MXE_TARGET_THREAD=.posix
ARG MXE_TARGET_LINK=shared
ARG ADD_UNITS=OFF
ARG CMAKE_VERSION=3.27.9
ARG BROKEN_PLUGINS="ParserROS ToolboxFFT ToolboxQuaternion DataLoadMCAP"

ENV MXE=/usr/src/mxe
ENV MXE_TARGET=${MXE_TARGET_ARCH}-w64-mingw32${MXE_TARGET_LINK:+.${MXE_TARGET_LINK}}${MXE_TARGET_THREAD}
ENV PATH=/usr/local/bin:${MXE}/usr/bin:${PATH}
ENV INSTALL_PREFIX=/work/pj_install
ENV CMAKE=${MXE_TARGET}-cmake

WORKDIR /work

# Debian Stretch is EOL; repoint apt to the archive and disable signature/date checks,
# since the original signing keys have expired.
RUN sed -i \
        -e 's|http://ftp.debian.org/debian|http://archive.debian.org/debian|g' \
        -e 's|http://cdn-fastly.deb.debian.org/debian|http://archive.debian.org/debian|g' \
        -e '/stretch-backports/d' -e '/stretch-updates/d' \
        /etc/apt/sources.list && \
    printf 'Acquire::Check-Valid-Until "false";\nAcquire::AllowInsecureRepositories "true";\nAPT::Get::AllowUnauthenticated "true";\n' \
        > /etc/apt/apt.conf.d/99no-check-valid-until && \
    apt-get update && \
    apt-get install -y --no-install-recommends --allow-unauthenticated wget && \
    rm -rf /var/lib/apt/lists/*

# MXE bundles CMake 3.15.4, too old for some PlotJuggler 3rdparty deps - install a newer one.
RUN wget --no-check-certificate -q \
        https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.sh \
        -O /tmp/cmake.sh && \
    sh /tmp/cmake.sh --skip-license --prefix=/usr/local && \
    rm /tmp/cmake.sh

# Fetch PlotJuggler core. It's built and installed standalone (not in-tree with the
# plugin), since the plugin expects an installed plotjugglerConfig.cmake via find_package().
RUN git clone --recurse-submodules --branch ${PJ_TAG} --depth 1 \
        https://github.com/facontidavide/PlotJuggler.git PlotJuggler && \
    find PlotJuggler -path "*3rdparty*/CMakeLists.txt" -exec \
        sed -i -E 's/cmake_minimum_required\(VERSION [0-9.]+/cmake_minimum_required(VERSION 3.10/I' {} +

# Disable plugins that don't cross-compile cleanly for MinGW shared libs:
#   ParserROS          - Fast-CDR dllimport/dllexport mismatch
#   ToolboxFFT/Quaternion - undefined reference to QDomDocument
#   DataLoadMCAP        - undefined reference to mcap reader symbols
# We don't need any of these for the apbin plugin.
RUN for plugin in ${BROKEN_PLUGINS}; do \
        sed -i -E "/add_subdirectory\([^)]*${plugin}[^)]*\)/ s/^/#/" PlotJuggler/CMakeLists.txt; \
    done && \
    rm -rf $(printf 'PlotJuggler/plotjuggler_plugins/%s ' ${BROKEN_PLUGINS})

# Configure, build and install PlotJuggler core (generates plotjugglerConfig.cmake).
WORKDIR /work/PlotJuggler
RUN mkdir build && cd build && \
    ${CMAKE} .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
        -DBUILD_SHARED_LIBS=ON && \
    ${CMAKE} --build . --target install -- -j$(nproc)

# Build the apbin plugin as a standalone project against the installed PlotJuggler.
WORKDIR /work
RUN git clone --recurse-submodules \
        https://github.com/Jair-F/plotjuggler-apbin-plugins.git apbin-plugin && \
    if [ "$ADD_UNITS" = "ON" ]; then \
        sed -i 's#//#define LABEL_WITH_UNIT#define LABEL_WITH_UNIT#' \
            apbin-plugin/dataload_apbin.cpp || true; \
    fi

WORKDIR /work/apbin-plugin
RUN mkdir build && cd build && \
    ${CMAKE} .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH=${INSTALL_PREFIX} \
        -Dplotjuggler_DIR=${INSTALL_PREFIX}/lib/cmake/plotjuggler \
        -DBUILD_SHARED_LIBS=ON && \
    ${CMAKE} --build . -- -j$(nproc)

# Export PlotJuggler core binaries and the compiled plugin DLL.
FROM scratch AS export-stage
COPY --from=builder /work/pj_install/bin/ /pj_core/
COPY --from=builder /work/apbin-plugin/build/*.dll /plugin/