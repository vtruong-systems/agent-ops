FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    AGENT_OPS_ROOT=/app

WORKDIR /app

COPY pyproject.toml README.md ./
COPY agent_ops ./agent_ops
RUN pip install --no-cache-dir .

COPY agents ./agents
COPY evals ./evals

RUN useradd --create-home --uid 10001 agentops \
    && chown -R agentops:agentops /app

USER 10001:10001
EXPOSE 8080
CMD ["python", "-m", "agent_ops.server"]
