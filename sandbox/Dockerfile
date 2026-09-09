FROM openclaw-sandbox:bookworm-slim

ARG INSTALL_PLAYWRIGHT_CHROMIUM=0

USER root

COPY apt-packages.txt /tmp/openclaw-apt-packages.txt
COPY pip-packages.txt /tmp/openclaw-pip-packages.txt

RUN apt-get update \
 && grep -Ev '^[[:space:]]*(#|$)' /tmp/openclaw-apt-packages.txt \
      | xargs -r apt-get install -y --no-install-recommends \
 && python3 -m pip install --no-cache-dir --break-system-packages \
      -r /tmp/openclaw-pip-packages.txt \
 && if [ "$INSTALL_PLAYWRIGHT_CHROMIUM" = "1" ]; then \
      python3 -m playwright install --with-deps chromium; \
    fi \
 && rm -rf /var/lib/apt/lists/* /tmp/openclaw-apt-packages.txt /tmp/openclaw-pip-packages.txt

USER sandbox
