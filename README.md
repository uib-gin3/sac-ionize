# Ionize

If you physically ionize ozone you can make it spark.


## Abstract

An Apache Ozone cluster (scm, om, recon and 3 datanodes) that stores the
goodreads dataset with replication factor 3, and an Apache Spark cluster
(a master and 3 workers) that reads it from Ozone through the `ofs://` file
system and, using `RDD` primitives, will compute the graph between authors
and reviewers (next interactions).


## Assignment

> - Set up an Apache Ozone cluster (ideally 3 nodes)
> - Set up an Apache Spark cluster (ideally 3 nodes)
> - Data: https://github.com/wisaaco/goodreads_etl_pipeline
> - Using `RDD` primitives, generate (and save) the resulting graph between authors and
>   reviewers. Regarding the graph structure:
>   - What is the distribution of reviewers per author?
>   - How many reviews does an author have?
>   - What recommendation would you give to a user who has 2* common edges with another?
> - Deliverable: Repository + report (notebook, doc, PDF, etc.)
> - In case of AI use, I want your AI prompts.


## Setup

Tested on Debian 13 with Docker 29.x and the compose plugin. The stack is
sized for a laptop: it idles around 3 GB of RAM and peaks around 4.5 GB
while a small job runs, and every container has a hard memory cap so it can
never eat the host. Disk-wise, the cluster data lives inside the repository
(`./data`), so leave a few GB free where you clone it: Ozone refuses to
write on filesystems with less than ~2% free and wants room for its
containers.

    git clone https://github.com/uib-gin3/sac-ionize
    cd sac-ionize

The first start pulls `apache/ozone:2.2.2` and `apache/spark:4.3.0` (~1.7
GB of images) and builds the Spark image on top, adding the Ozone connector.


## Usage

### Start

    docker compose up -d --build    # plain up -d after the first build

11 services (the one-shot `data-init` exits 0 by design):

    docker compose ps

Watch: SCM http://localhost:9876, OM http://localhost:9874, Recon
http://localhost:9888 and Spark master http://localhost:8080 (workers at
8081, 8082 and 8083).

The cluster becomes writable when SCM leaves safe mode: the 3 datanodes
register and the first RATIS/THREE pipeline opens (~1 minute; `./load-dataset`
fails politely meanwhile, just retry).

### Load the dataset into Ozone

    ./load-dataset

It execs into the om container (the dataset is mounted read-only at
`/dataset`) and ends listing `ofs://om/goodreads/dataset`: the 4 CSVs, each
with 3 replicas (one per datanode). It is re-runnable (volume and bucket
are created when missing, keys are overwritten) and takes volume and bucket
as parameters:

    ./load-dataset other-volume other-bucket

Or manually, to see the Ozone shell at work:

    docker compose exec om ozone sh volume create goodreads
    docker compose exec om ozone sh bucket create goodreads/dataset
    docker compose exec om ozone fs -put /dataset/*.csv ofs://om/goodreads/dataset/

### Spark

    docker compose exec spark-master /opt/spark/bin/pyspark --master spark://spark-master:7077
    >>> rdd = sc.textFile("ofs://om/goodreads/dataset/reviews.csv")
    >>> rdd.count()

With `fs.defaultFS` pointed at `ofs://om` in the image, plain paths work
too: `sc.textFile("/goodreads/dataset/reviews.csv")`.

### Stop

    docker compose down                  # data survives in ./data
    docker compose up -d                 # back in under a minute, dataset intact
    docker compose down && rm -rf data   # full reset


## Design decisions

Official images, one Ozone role per container: scm (block management), om
(namespace) and recon (monitoring) form the control plane, and datanode1-3
are the 3 Ozone nodes storing data with replication factor 3.

Configuration is environment driven (`OZONE-SITE.XML_*`), the official
ozone-docker compose pattern, plus the runner's startup helpers (`ENSURE_*`,
`WAITFOR`) to order scm → om → recon deterministically.

Spark reaches Ozone through the `ozone-filesystem-hadoop3` jar (versions
matched to the cluster) and a `core-site.xml` baked into a small Dockerfile
on top of `apache/spark:4.3.0`; `fs.defaultFS=ofs://om` so plain paths work.
The dataset is mounted read-only where it gets loaded from (om) and where
the RDD work happens (the spark containers).

The cluster data lives in `./data`, bind-mounted relative to the compose
file, so the repository is portable: clone it anywhere and the data follows
(and is visible with a plain `ls data/dn1`). A one-shot `data-init` service
leaves it owned by uid 1000, the hadoop user of the Ozone containers,
whoever clones it.

Datanodes register by hostname instead of container IP
(`hdds.datanode.use.datanode.hostname=true`): ratis persists the peer
addresses of its pipelines and docker churns IPs on every boot, which
orphaned them (we hit exactly that; see Observations).

Sized for a 16 GB laptop: `OZONE_HEAPSIZE` 1 GB per Ozone role, 512 MB
Spark daemons, 512 MB driver/executors, and `mem_limit` = `memswap_limit`
per container, so a hungry container is OOM-killed instead of filling swap.
Absolute ceiling ~13.5 GB; real usage far below (see Observations).


## Observations

`docker stats` on the real run, idle → while the count smoke test runs:

    container          limit    idle        job
    scm                1.5GiB   ~330 MiB    ~330 MiB
    om                 1.5GiB   ~340 MiB    ~335 MiB
    recon              768MiB   ~340 MiB    ~335 MiB
    datanode1-3        1.5GiB   ~360-380    ~355-365
    spark-master       768MiB   ~200 MiB    ~205 MiB
    spark-worker-1-3   1.5GiB   ~195-215    ~570-620

Total: ~3 GB idle, ~4.5 GB with the 3 executors (512 MB, 2 cores each) up —
the caps stay far away. The worker spike is the executor JVM plus its 3
Python workers.

The first write after a boot waits for SCM safe mode: with the 15 s
pipeline creation interval (2 min by default) the cluster is writable in
under a minute, and a restart with data present reopens the pipelines in
~45 s. Counting `reviews.csv` over `ofs://` from pyspark returns 1652
lines: 1651 reviews plus the header.

One trap worth keeping: the ozone jar `ADD`ed into the Spark image lands
root-owned with mode 600, and the JVM silently skips unreadable jars on a
wildcard classpath — `RootedOzoneFileSystem` not found until `chmod 0644`.


## AI usage

The used prompts can be found in PROMPT.md

### Models & tools

- MiMo-V2.6-Flash (opencode): Assignment translation
- GLM-5.3-Flash (opencode): docker compose for the Ozone + Spark clusters,
  the Spark image with the Ozone connector, load-dataset and README
  (interactions 2-5 of PROMPT.md).
