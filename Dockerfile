# Spark with the Ozone connector: apache/spark plus the ozone filesystem jar
# (matching the apache/ozone:2.2.2 cluster of this repo) and the configs that
# point it at the cluster. Built by docker-compose for every spark container.
# https://ozone.apache.org/docs/user-guide/integrations/spark/
FROM apache/spark:4.3.0

USER root

ADD https://repo1.maven.org/maven2/org/apache/ozone/ozone-filesystem-hadoop3/2.2.2/ozone-filesystem-hadoop3-2.2.2.jar /opt/spark/jars/

# ADD downloads land root-owned with 600: unreadable by the spark user, and
# the JVM silently skips unreadable jars on a wildcard classpath.
RUN chmod 0644 /opt/spark/jars/ozone-filesystem-hadoop3-2.2.2.jar

COPY spark-conf/core-site.xml spark-conf/spark-defaults.conf /opt/spark/conf/

USER spark
