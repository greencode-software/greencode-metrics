FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir requests==2.32.3 pyyaml==6.0.2
COPY sentry_poller/ ./sentry_poller/
COPY config.yml ./config.yml
ENTRYPOINT ["python", "-m", "sentry_poller"]
