package com.example.auth_service.service;

import com.example.auth_service.dto.LoginRequestDTO;
import com.example.auth_service.dto.MessageResponseDTO;
import com.example.auth_service.dto.RegisterRequestDTO;
import com.example.auth_service.dto.TokenResponseDTO;
import com.example.auth_service.entity.Role;
import com.example.auth_service.entity.User;
import com.example.auth_service.exception.InvalidCredentialsException;
import com.example.auth_service.exception.UserAlreadyExistsException;
import com.example.auth_service.repository.UserRepository;
import com.example.auth_service.security.JwtService;
import lombok.RequiredArgsConstructor;
import org.modelmapper.ModelMapper;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;


@Service
@RequiredArgsConstructor
public class AuthService {

    private final UserRepository userRepository;
    private final PasswordEncoder passwordEncoder;
    private final JwtService jwtService;
    private final ModelMapper modelMapper;
    private final EmailService emailService;

    
    public MessageResponseDTO register(RegisterRequestDTO dto) {
        // Check if user already exists
        if (userRepository.existsByEmail(dto.getEmail())) {
            throw new UserAlreadyExistsException("User with email " + dto.getEmail() + " already exists");
        }

        // ModelMapper: DTO → Entity (copies email automatically)
        User user = modelMapper.map(dto, User.class);

        // Set password hash (needs encoding - can't be done by ModelMapper)
        String hashedPassword = passwordEncoder.encode(dto.getPassword());
        user.setPasswordHash(hashedPassword);

        // Set role (String → Enum with fallback - can't be done by ModelMapper)
        Role role = Role.USER;
        if (dto.getRole() != null && !dto.getRole().isBlank()) {
            try {
                role = Role.valueOf(dto.getRole().toUpperCase());
            } catch (IllegalArgumentException e) {
                role = Role.USER;
            }
        }
        user.setRole(role);

        // Save to database
        userRepository.save(user);

        // Send welcome email asynchronously — fire-and-forget, non-blocking
        emailService.sendWelcomeEmail(user.getEmail());

        return MessageResponseDTO.builder()
                .message("User registered successfully")
                .build();
    }

    
    public TokenResponseDTO login(LoginRequestDTO dto) {
        User user = userRepository.findByEmail(dto.getEmail())
                .orElseThrow(() -> new InvalidCredentialsException("Invalid email or password"));

        boolean matches = passwordEncoder.matches(dto.getPassword(), user.getPasswordHash());
        if (!matches) {
            throw new InvalidCredentialsException("Invalid email or password");
        }

        String token = jwtService.generateToken(user.getEmail(), user.getRole().name());

        TokenResponseDTO response = TokenResponseDTO.builder()
                .accessToken(token)
                .tokenType("Bearer")
                .role(user.getRole().name())
                .email(user.getEmail())
                .build();
        return response;
    }
}
