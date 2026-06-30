# syntax=docker/dockerfile:1
FROM autoantwort/qt5-cross-compiled-windows-build-env:latest AS builder

ARG PJ_TAG=3.9.2
ARG MXE_TARGET_ARCH=x86_64
ARG MXE_TARGET_THREAD=.posix
ARG MXE_TARGET_LINK=shared
ARG ADD_UNITS=OFF
ARG CMAKE_VERSION=3.27.9

ENV MXE=/usr/src/mxe
ENV MXE_TARGET=${MXE_TARGET_ARCH}-w64-mingw32${MXE_TARGET_LINK:+.${MXE_TARGET_LINK}}${MXE_TARGET_THREAD}
ENV PATH=/usr/local/bin:${MXE}/usr/bin:${PATH}
ENV INSTALL_PREFIX=/work/pj_install

WORKDIR /work

# 1. Fix apt sources: this image is based on Debian Stretch, which is EOL and
#    only available via archive.debian.org now, with expired signing keys
RUN sed -i \
        -e 's|http://ftp.debian.org/debian|http://archive.debian.org/debian|g' \
        -e 's|http://cdn-fastly.deb.debian.org/debian|http://archive.debian.org/debian|g' \
        -e '/stretch-backports/d' \
        -e '/stretch-updates/d' \
        /etc/apt/sources.list && \
    printf 'Acquire::Check-Valid-Until "false";\nAcquire::AllowInsecureRepositories "true";\nAPT::Get::AllowUnauthenticated "true";\n' \
        > /etc/apt/apt.conf.d/99no-check-valid-until

# 2. Fetch a newer CMake binary (MXE bundles 3.15.4, too old for some PlotJuggler 3rdparty deps)
RUN apt-get update && \
    apt-get install -y --no-install-recommends --allow-unauthenticated wget && \
    wget --no-check-certificate -q https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.sh -O /tmp/cmake.sh && \
    sh /tmp/cmake.sh --skip-license --prefix=/usr/local && \
    rm /tmp/cmake.sh && \
    rm -rf /var/lib/apt/lists/*

# 3. Clone PlotJuggler core (built and installed standalone, WITHOUT the plugin in-tree)
RUN git clone --recurse-submodules --branch ${PJ_TAG} --depth 1 \
    https://github.com/facontidavide/PlotJuggler.git PlotJuggler

# 4. Patch any vendored 3rdparty submodules that require a CMake version newer than 3.15
RUN find PlotJuggler -path "*3rdparty*/CMakeLists.txt" -exec \
        sed -i -E 's/cmake_minimum_required\s*\(\s*VERSION\s+[0-9]+\.[0-9]+/cmake_minimum_required(VERSION 3.10/I' {} \; ; \
    true

# 5. Comment out the four add_subdirectory() calls in the top-level CMakeLists.txt that
#    reference plugins which fail to cross-compile cleanly for MinGW shared libs:
#      - DataLoadMCAP (line ~264): undefined reference to mcap reader symbols
#      - ToolboxQuaternion, ToolboxFFT (lines ~277-278): undefined reference to QDomDocument
#      - ParserROS (line ~282): Fast-CDR dllimport/dllexport mismatch
#    Confirmed via CMake's own error output exactly which add_subdirectory() lines reference them.
RUN sed -i -E \
        -e '/add_subdirectory\([^)]*DataLoadMCAP[^)]*\)/ s/^/#/' \
        -e '/add_subdirectory\([^)]*ToolboxQuaternion[^)]*\)/ s/^/#/' \
        -e '/add_subdirectory\([^)]*ToolboxFFT[^)]*\)/ s/^/#/' \
        -e '/add_subdirectory\([^)]*ParserROS[^)]*\)/ s/^/#/' \
        PlotJuggler/CMakeLists.txt && \
    grep -n "DataLoadMCAP\|ToolboxQuaternion\|ToolboxFFT\|ParserROS" PlotJuggler/CMakeLists.txt

# 6. Physically remove the now-unreferenced plugin source directories (safe no-op for
#    CMake configure, just keeps the build context smaller)
RUN rm -rf \
        PlotJuggler/plotjuggler_plugins/ParserROS \
        PlotJuggler/plotjuggler_plugins/ToolboxFFT \
        PlotJuggler/plotjuggler_plugins/ToolboxQuaternion \
        PlotJuggler/plotjuggler_plugins/DataLoadMCAP

# 7. Configure, build, and install PlotJuggler core (this generates plotjugglerConfig.cmake)
WORKDIR /work/PlotJuggler
RUN mkdir build && cd build && \
    ${MXE_TARGET}-cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
        -DBUILD_SHARED_LIBS=ON && \
    ${MXE_TARGET}-cmake --build . --target install -- -j$(nproc)

# 8. Clone your plugin fork into a separate standalone directory
WORKDIR /work
RUN git clone --recurse-submodules \
    https://github.com/Jair-F/plotjuggler-apbin-plugins.git \
    apbin-plugin

# 9. (Optional) enable unit labels, matching upstream's ADD_UNITS flag
RUN if [ "$ADD_UNITS" = "ON" ]; then \
        sed -i 's/\/\/#define LABEL_WITH_UNIT/#define LABEL_WITH_UNIT/' \
        apbin-plugin/dataload_apbin.cpp || true; \
    fi

# 10. Configure the plugin standalone against the installed PlotJuggler package config
WORKDIR /work/apbin-plugin
RUN mkdir build && cd build && \
    ${MXE_TARGET}-cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH=${INSTALL_PREFIX} \
        -Dplotjuggler_DIR=${INSTALL_PREFIX}/lib/cmake/plotjuggler \
        -DBUILD_SHARED_LIBS=ON

# 11. Build the plugin
RUN cd build && \
    ${MXE_TARGET}-cmake --build . -- -j$(nproc)

# 12. Collect the resulting Windows DLL(s)/EXE from both PlotJuggler core and the plugin
FROM scratch AS export-stage
COPY --from=builder /work/pj_install/bin/ /pj_core/
COPY --from=builder /work/apbin-plugin/build/*.dll /plugin/