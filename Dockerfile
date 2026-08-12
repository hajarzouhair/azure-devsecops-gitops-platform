# --- Étape 1 : build avec Maven ---
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
# Télécharge les dépendances séparément : mise en cache Docker,
# accélère les builds suivants si le pom.xml ne change pas.
RUN mvn -B dependency:go-offline
COPY src ./src
RUN mvn -B package -DskipTests

# --- Étape 2 : image finale, légère, sans Maven ni sources ---
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar

# Bonne pratique sécurité : ne pas exécuter en root dans le conteneur.
RUN addgroup -S spring && adduser -S spring -G spring
USER spring

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
