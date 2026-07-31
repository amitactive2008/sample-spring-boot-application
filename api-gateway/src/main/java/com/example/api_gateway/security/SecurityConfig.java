package com.example.api_gateway.security;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.authentication.AbstractAuthenticationToken;
import org.springframework.security.config.annotation.web.reactive.EnableWebFluxSecurity;
import org.springframework.security.config.web.server.ServerHttpSecurity;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.ReactiveJwtDecoder;
import org.springframework.security.oauth2.jwt.NimbusReactiveJwtDecoder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.security.web.server.SecurityWebFilterChain;
import org.springframework.core.convert.converter.Converter;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.reactive.CorsConfigurationSource;
import org.springframework.web.cors.reactive.UrlBasedCorsConfigurationSource;
import reactor.core.publisher.Mono;

import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

@Configuration
@EnableWebFluxSecurity
public class SecurityConfig {

    @Value("${cors.allowed-origin:http://localhost:3000}")
    private String allowedOrigin;

    @Bean
    public SecurityWebFilterChain securityWebFilterChain(ServerHttpSecurity http) {
        http.csrf(ServerHttpSecurity.CsrfSpec::disable);
        http.cors(cors -> cors.configurationSource(corsConfigurationSource()));
        http.authorizeExchange(ex -> ex
                // Allow preflight OPTIONS requests
                .pathMatchers(HttpMethod.OPTIONS, "/**").permitAll()
                // Auth login/register are public
                .pathMatchers("/auth/register", "/auth/login").permitAll()
                .pathMatchers("/actuator/**").permitAll()
                // User management (ADMIN only)
                .pathMatchers(HttpMethod.GET, "/auth/users/**").hasRole("ADMIN")
                .pathMatchers(HttpMethod.DELETE, "/auth/users/**").hasRole("ADMIN")
                // Issue endpoints
                .pathMatchers(HttpMethod.GET, "/issues/**").hasAnyRole("USER", "ADMIN")
                .pathMatchers(HttpMethod.POST, "/issues/**").hasAnyRole("USER", "ADMIN")
                .pathMatchers(HttpMethod.PUT, "/issues/**").hasAnyRole("USER", "ADMIN")
                .pathMatchers(HttpMethod.PATCH, "/issues/**").hasAnyRole("USER", "ADMIN")
                .pathMatchers(HttpMethod.DELETE, "/issues/**").hasAnyRole("USER", "ADMIN")
                .anyExchange().authenticated()
        );
        http.oauth2ResourceServer(oauth2 -> oauth2
                .jwt(jwt -> jwt.jwtAuthenticationConverter(jwtAuthConverter()))
        );
        return http.build();
    }

    @Bean
    public CorsConfigurationSource corsConfigurationSource() {
        CorsConfiguration config = new CorsConfiguration();
        config.setAllowedOrigins(List.of(allowedOrigin));
        config.setAllowedMethods(Arrays.asList("GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"));
        config.setAllowedHeaders(List.of("*"));
        config.setAllowCredentials(true);
        config.setMaxAge(3600L);

        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/**", config);
        return source;
    }

    private Converter<Jwt, Mono<AbstractAuthenticationToken>> jwtAuthConverter() {
        return jwt -> {
            String role = jwt.getClaimAsString("role");
            if (role == null) role = "USER";
            role = role.toUpperCase();
            String authority = "ROLE_" + role;
            List<SimpleGrantedAuthority> authorities =
                    Collections.singletonList(new SimpleGrantedAuthority(authority));
            return Mono.just(new JwtAuthenticationToken(jwt, authorities));
        };
    }

    @Bean
    public ReactiveJwtDecoder reactiveJwtDecoder(@Value("${jwt.secret}") String secret) {
        SecretKeySpec key = new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256");
        return NimbusReactiveJwtDecoder.withSecretKey(key).build();
    }
}
