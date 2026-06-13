ARG GDAL_IMAGE=ghcr.io/osgeo/gdal:ubuntu-small-3.11.4
FROM ${GDAL_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-pip python3-venv \
    && python3 -m venv --system-site-packages /opt/venv \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY publisher.py generate_demo.py ./
RUN chown -R 1000:1000 /app

USER 1000:1000
ENTRYPOINT ["python", "/app/publisher.py"]
