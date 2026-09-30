FROM ghcr.io/astral-sh/uv:latest AS uv

FROM debian:trixie-slim

COPY --from=uv /uv /usr/local/bin/uv

ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python \
    UV_PYTHON_BIN_DIR=/usr/local/bin \
    PYTHON_GIL=0 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && uv python install 3.14t --default \
    && python -c 'import sys, sysconfig; assert sysconfig.get_config_var("Py_GIL_DISABLED") == 1; assert sys._is_gil_enabled() is False; print(sys.version)'

WORKDIR /app
COPY server.py /app/server.py

USER 65532:65532
EXPOSE 8080

CMD ["python", "/app/server.py"]
