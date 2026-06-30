FROM ubuntu:22.04 AS build-stage

ARG ADD_UNITS=OFF

RUN apt update && apt install -y build-essential cmake git

RUN apt update && apt -y install qtbase5-dev libqt5svg5-dev libqt5websockets5-dev \
    libqt5opengl5-dev libqt5x11extras5-dev libprotoc-dev libzmq3-dev

WORKDIR /plotjuggler_ws/src
RUN git clone --depth 1 --branch 3.9.2 https://github.com/facontidavide/PlotJuggler.git PlotJuggler

WORKDIR /plotjuggler_ws
RUN cmake -S src/PlotJuggler -B build/PlotJuggler -DCMAKE_INSTALL_PREFIX=install \
    && cmake --build build/PlotJuggler --config RelWithDebInfo --target install -- -j"$(nproc)"

COPY --link . /apbin_plugin

WORKDIR /apbin_plugin/build

# Ensure a fresh build folder (safe even if already empty, unlike `rm -R *`)
RUN find . -mindepth 1 -delete \
    && cmake -Dplotjuggler_DIR="/plotjuggler_ws/install/lib/cmake/plotjuggler" -DADD_UNITS=${ADD_UNITS} .. \
    && make -j"$(nproc)" \
    && make install \
    && mkdir /artifacts \
    && cp libDataAPBin.so /artifacts

FROM scratch AS export-stage
# Move the plugin to a fresh filesystem that can be exported easily.
COPY --from=build-stage /artifacts /
