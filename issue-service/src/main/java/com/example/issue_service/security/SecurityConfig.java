package com.example.issue_service.security;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;

@Configuration
public class SecurityConfig {

    private final JwtAuthenticationFilter jwtFilter;

    public SecurityConfig(JwtAuthenticationFilter jwtFilter) {
        this.jwtFilter = jwtFilter;
    }

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http.csrf(csrf -> csrf.disable());
        http.sessionManagement(sm -> sm.sessionCreationPolicy(SessionCreationPolicy.STATELESS));
        http.addFilterBefore(jwtFilter, UsernamePasswordAuthenticationFilter.class);
        http.authorizeHttpRequests(auth -> auth
                .requestMatchers("/actuator/**").permitAll()
                // Both USER and ADMIN can view issues
                .requestMatchers(HttpMethod.GET, "/issues/**").hasAnyRole("USER", "ADMIN")
                // Both USER and ADMIN can create issues
                .requestMatchers(HttpMethod.POST, "/issues/**").hasAnyRole("USER", "ADMIN")
                // Both USER and ADMIN can update issues
                .requestMatchers(HttpMethod.PUT, "/issues/**").hasAnyRole("USER", "ADMIN")
                // Both USER and ADMIN can update status (PATCH)
                .requestMatchers(HttpMethod.PATCH, "/issues/**").hasAnyRole("USER", "ADMIN")
                // Both USER and ADMIN can delete issues
                .requestMatchers(HttpMethod.DELETE, "/issues/**").hasAnyRole("USER", "ADMIN")
                .anyRequest().authenticated()
        );
        return http.build();
    }
}
