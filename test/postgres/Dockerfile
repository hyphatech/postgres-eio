# Postgres refuses a key anyone else can read, so modes are set explicitly
# rather than inherited from the checkout's umask.
FROM postgres:18-alpine
# COPY --chmod would give a directory it creates the files' mode, without x.
RUN mkdir -m 0755 /etc/postgres-test
COPY --chown=postgres:postgres --chmod=0600 server.key /etc/postgres-test/
COPY --chmod=0644 server.crt client-ca.crt pg_hba.conf /etc/postgres-test/
