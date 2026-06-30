#!/bin/bash
mkdir -p artifacts
docker buildx build -f windows.Dockerfile --build-arg ADD_UNITS=ON -o type=local,dest=artifacts --progress=plain .
