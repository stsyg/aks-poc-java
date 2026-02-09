---
applyTo: "**/*.java"
---

# Java / Spring Boot Instructions

## Language & Runtime
- Use **Java 21** (Microsoft OpenJDK distribution).
- Target **Spring Boot 3.x** with Spring Cloud.

## Coding Conventions
- Use **constructor injection** — never field injection (`@Autowired` on fields).
- Prefer `record` types for DTOs and value objects.
- Use `Optional` return types for nullable queries.
- Follow standard Java naming conventions (camelCase methods, PascalCase classes).

## Spring Boot Patterns
- Always expose **Actuator health endpoints** (`/actuator/health`) for Kubernetes probes.
- Use `@RestController` with `@RequestMapping` for API endpoints.
- Use Spring Cloud Config for externalized configuration.
- Use Spring Cloud Discovery (Eureka) for service registration.
- Use Spring Cloud Gateway for API routing.

## Observability
- Enable **Micrometer Prometheus registry** for metrics export.
- Spring Boot Actuator metrics are scraped by Azure Monitor Managed Prometheus.
- Include `spring-boot-starter-actuator` and `micrometer-registry-prometheus` dependencies.

## Testing
- Use JUnit 5 with `@SpringBootTest` for integration tests.
- Use `@WebMvcTest` for controller-level tests.
