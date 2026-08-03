package com.example.auth_service.security;

import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertEquals;

class JwtServiceTest {

    private static final String SECRET =
            "test-only-signing-secret-that-is-longer-than-32-characters";

    @Test
    void generatesHs256TokensForGatewayCompatibility() {
        JwtService jwtService = new JwtService();
        ReflectionTestUtils.setField(jwtService, "jwtSecret", SECRET);
        ReflectionTestUtils.setField(jwtService, "expirationMinutes", 60L);

        String token = jwtService.generateToken("admin@example.test", "ADMIN");

        String algorithm = Jwts.parser()
                .verifyWith(Keys.hmacShaKeyFor(SECRET.getBytes(StandardCharsets.UTF_8)))
                .build()
                .parseSignedClaims(token)
                .getHeader()
                .getAlgorithm();

        assertEquals("HS256", algorithm);
    }
}
