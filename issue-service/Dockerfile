FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN mvn -DskipTests package -B --no-transfer-progress

FROM eclipse-temurin:21-jre
WORKDIR /app
# Run as non-root for security (Trivy DS-0002 / Hadolint DL3002)
RUN groupadd --system appgroup && useradd --system --gid appgroup --no-create-home appuser
COPY --from=build /app/target/*.jar app.jar
RUN chown appuser:appgroup app.jar
USER appuser
EXPOSE 8098
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -sf http://localhost:8098/actuator/health || exit 1
ENTRYPOINT ["java","-jar","app.jar"]
