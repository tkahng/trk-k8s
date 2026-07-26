# Phase 7.3 — postgres:18 + Patroni, hand-assembled (ADR 006).
# The official postgres image ships no Patroni; the Patroni project ships
# no production image; Spilo was rejected because it generates the config
# we're here to write. So: the same postgres:18 from 7.1, plus Patroni.
FROM postgres:18

# Debian's PEP-668 guard blocks system-wide pip installs, so Patroni gets
# its own venv. patroni[kubernetes] pulls the k8s DCS support; psycopg is
# Patroni's database driver.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv \
 && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/patroni \
 && /opt/patroni/bin/pip install --no-cache-dir \
      'patroni[kubernetes]' \
      'psycopg[binary]'
ENV PATH="/opt/patroni/bin:$PATH"

# Patroni is PID 1 and drives initdb/pg_ctl itself — the stock
# docker-entrypoint.sh (and its POSTGRES_PASSWORD flow) is out of the
# picture on purpose. patroni.yml arrives via ConfigMap mount.
USER postgres
ENTRYPOINT []
CMD ["patroni", "/etc/patroni/patroni.yml"]
