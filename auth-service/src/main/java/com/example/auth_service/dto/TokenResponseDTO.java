package com.example.auth_service.dto;

import lombok.*;

@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class TokenResponseDTO {

    private String accessToken;
    private String tokenType; // "Bearer"
    private String role;
    private String email;
}
