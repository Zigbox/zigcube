# demo-c2's python-app (C2 brief, O8). v1 and v2 differ only in app.py, which is
# the last layer on its own, so a v2 rollout moves kilobytes, not the base.
FROM python:3.12-slim@sha256:BASE_DIGEST
WORKDIR /app
COPY app.py /app/app.py
CMD ["python", "/app/app.py"]
