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

# Met à jour les paquets Alpine pour récupérer les correctifs de sécurité
RUN apk update && apk upgrade

WORKDIR /app

COPY --from=build /app/target/*.jar app.jar

# Bonne pratique sécurité : ne pas exécuter en root dans le conteneur.
# UID/GID numériques fixes (1001) obligatoires : Kubernetes doit pouvoir
# vérifier que le conteneur ne tourne pas en root (runAsNonRoot dans
# deployment.yaml), et ne peut pas le faire avec un simple nom d'utilisateur.
RUN addgroup -g 1001 -S spring && adduser -u 1001 -S spring -G spring
USER 1001

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
