FROM openclaw-sandbox:bookworm-slim

USER root

COPY apt-packages.txt /tmp/openclaw-apt-packages.txt
COPY pip-packages.txt /tmp/openclaw-pip-packages.txt

RUN apt-get update \
 && grep -Ev '^[[:space:]]*(#|$)' /tmp/openclaw-apt-packages.txt \
      | xargs -r apt-get install -y --no-install-recommends \
 && python3 -m pip install --no-cache-dir --break-system-packages \
      -r /tmp/openclaw-pip-packages.txt \
 && rm -rf /var/lib/apt/lists/* /tmp/openclaw-apt-packages.txt /tmp/openclaw-pip-packages.txt

USER sandbox
