#!/bin/bash
mkdir -p artifacts
docker buildx build -f windows.Dockerfile -o type=local,dest=artifacts --progress=plain .