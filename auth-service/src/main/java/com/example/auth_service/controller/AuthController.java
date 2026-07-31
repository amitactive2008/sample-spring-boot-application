package com.example.auth_service.controller;

import com.example.auth_service.dto.LoginRequestDTO;
import com.example.auth_service.dto.MessageResponseDTO;
import com.example.auth_service.dto.RegisterRequestDTO;
import com.example.auth_service.dto.TokenResponseDTO;
import com.example.auth_service.service.AuthService;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/auth")
public class AuthController {

    private final AuthService authService;

    public AuthController(AuthService authService) {
        this.authService = authService;
    }

    @PostMapping("/register")
    public MessageResponseDTO register(@Valid @RequestBody RegisterRequestDTO dto) {
        return authService.register(dto);
    }

    @PostMapping("/login")
    public TokenResponseDTO login(@Valid @RequestBody LoginRequestDTO dto) {
        return authService.login(dto);
    }
}
