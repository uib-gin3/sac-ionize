# sac-ionize prompt log

This file keeps the prompt of the assignment plus the interactions that
shaped the implementation. The idea: with this file, an empty repository
and an AI coding agent, more or less the same implementation comes out.

## Interaction 1 - Translate assignment

> "Translate to english SAC_slides/slides/unit10/tema-10-mapreduce.html#/entregable and store it as /tmp/aa.md"

## Interaction 2 - Create docker & docker compose for ozone + spark

This is the 4rt assignment from the university covering the subject 21794 - Sistemes Actuals de Computació at the University of the Balearic Islands.

You can find the syllabus at https://academic.uib.es/doa/consultaPublica/look%5bconpub%5dMostrarPubGuiaDocAs?entradaPublica=true&idiomaPais=es.ES&_anoAcademico=2026&_codAsignatura=21794

I've already done three other assignments that you'll find at:
- /home/bartomeu/src/gin3-2026-27/sac-sock-calc
- /home/bartomeu/src/gin3-2026-27/sac-restad
- /home/bartomeu/src/gin3-2026-27/sac-strike

I want you to follow that style.

On this assignment is important to keep the PROMPT.md with the log of all prompts. You can take the sac-strike/PROMPT.md as example.

Create a docker-compose with 3 Apache Ozone nodes and 3 Apache Spark nodes mounting the dataset directory in order to load it.

Document on the readme how to start them.

Decisions:

- One `docker-compose.yml` for everything: Ozone control plane (scm, om,
  recon) plus datanode1-3 as the 3 Ozone nodes (replication factor 3), and
  Spark master + worker1-3. Official images, one role per container:
  `apache/ozone:2.2.2`, `apache/spark:4.3.0`.
- Configuration as environment variables (`OZONE-SITE.XML_*`), the official
  ozone-docker compose pattern, plus the runner's startup helpers
  (`ENSURE_SCM_INITIALIZED`, `ENSURE_OM_INITIALIZED`, `WAITFOR`) ordering
  scm → om → recon.
- Spark reaches Ozone through a small Dockerfile on top of `apache/spark`:
  the `ozone-filesystem-hadoop3` jar (versions matched) from Maven Central
  plus `core-site.xml` (`fs.ofs.impl`, `fs.defaultFS=ofs://om`) and
  `spark-defaults.conf` (512 MB driver/executors). Built once by compose
  for the master and the three workers.
- The dataset is mounted read-only into om (the loader) and the spark
  containers; `./load-dataset` execs into om and loads the 4 CSVs as
  `ofs://om/goodreads/dataset`, idempotently (ozone fs -mkdir -p + -put -f),
  taking volume/bucket as parameters so the later demo automation can reuse
  it.
- Host ports: the four web UIs (9876 scm, 9874 om, 9888 recon, 8080 spark
  master), spark rpc 7077 and the worker UIs at 8081-8083.
- Two bugs found while verifying, both documented in the README:
  - the ozone jar ADDed into the Spark image lands root-owned mode 600, the
    JVM silently skips unreadable jars on a wildcard classpath, and
    `RootedOzoneFileSystem` goes missing until `chmod 0644`;
  - the first boot needs the first RATIS/THREE pipeline before SCM leaves
    safe mode; the 2-minute default `ozone.scm.pipeline.creation.interval`
    was shortened to 15 s.

## Interaction 3 - RAM requirements

> "How much RAM is needed to use it? Document it also it at the readme."

Decisions:

- Measured, not estimated: the numbers in the README come from
  `docker stats` on the real run (idle vs while the smoke job runs), not
  from arithmetic.
- Heaps tuned down from the production defaults for a 16 GB laptop:
  `OZONE_HEAPSIZE` 1024 MB per Ozone role (512 MB for recon),
  `SPARK_DAEMON_MEMORY`/driver/executors 512 MB. Real usage: ~3 GB idle,
  ~4.5 GB peak with the 3 executors up — the JVMs idle far below their
  `-Xmx`.

## Interaction 4 - container limits

> "Can you set limits to the containers to avoid consuming too much?"

Decisions:

- Every container gets `mem_limit` = `memswap_limit` (no swap bleed):
  1536 MB for scm, om, datanodes and workers; 768 MB for recon and the
  spark master. The caps sit a bit above the tuned heaps, so a runaway
  container is OOM-killed (visible) instead of eating the laptop.
- Executors run inside the worker containers, so the Spark defaults live in
  `spark-defaults.conf` (512 MB) keeping the workers inside their cap;
  `SPARK_WORKER_CORES=2`, `SPARK_WORKER_MEMORY=1g`.
- CPU untouched: idle JVMs barely use it and the workers only offer 2 cores
  each. Absolute ceiling ~13.5 GB, real usage ~3-4.5 GB.

## Interaction 5 - data on another path, relative and portable

> "Can docker use space from another path other than the default one, like setting en envar or some docker-compose setting? ... I just want to know how to do it. I would like to use the space of the current directory anything that needs to be downloaded to be stored here. I would like the path to be relative so is portable"

Decisions:

- The cluster data moved from named volumes to relative bind mounts under
  `./data` (one subdir per role, like separate disks per node), resolved
  against the compose file: the repository is portable and the data is
  visible with plain `ls`. Reset is `docker compose down && rm -rf data`.
- Root-owned bind dirs break Ozone (uid 1000 cannot chmod), so a one-shot
  `data-init` service mkdirs the subdirs and chowns them to uid 1000 (the
  containers' hadoop user) before anything starts: works for whoever
  clones, on any machine. The custom ozone image built for the volume
  ownership trick became unnecessary and was dropped.
- Moving *images* (the "downloaded" part) needs Docker's `data-root` in
  `/etc/docker/daemon.json`: machine-wide config, absolute path only, no
  envvar — out of the repository's scope; documented for the host, not
  shipped.
- Two restart-with-persisted-data bugs hit on the way and fixed:
  - ratis persists pipeline peer addresses as container IPs, and docker
    churns IPs per boot, leaving the pipelines orphaned (`NOT_IN_CONF`,
    leader election livelock); datanodes now register by hostname
    (`hdds.datanode.use.datanode.hostname=true`), stable across boots;
  - Ozone also refuses nodes with little free space (5 GB data + 1 GB
    metadata per datanode): with the data on the small root disk the
    pipelines never formed. The bind mounts now live where the space is.
- Verified end to end: `down` → `up` keeps the dataset, pipelines reopen in
  ~45 s, `./load-dataset` overwrites cleanly, and the pyspark smoke test
  counts 6608 lines across the 4 CSVs (1652 in reviews.csv) through
  `ofs://om` from the 3-executor cluster.
