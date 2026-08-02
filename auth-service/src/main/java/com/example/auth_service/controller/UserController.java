package com.example.auth_service.controller;

import com.example.auth_service.dto.UserResponseDTO;
import com.example.auth_service.service.UserManagementService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/auth/users")
public class UserController {

    private final UserManagementService userManagementService;

    public UserController(UserManagementService userManagementService) {
        this.userManagementService = userManagementService;
    }

    // GET /auth/users - List all users (ADMIN only)
    @GetMapping
    public ResponseEntity<List<UserResponseDTO>> getAllUsers() {
        return ResponseEntity.ok(userManagementService.getAllUsers());
    }

    // GET /auth/users/{id} - Get user by ID (ADMIN only)
    @GetMapping("/{id}")
    public ResponseEntity<UserResponseDTO> getUserById(@PathVariable Long id) {
        return ResponseEntity.ok(userManagementService.getUserById(id));
    }

    // DELETE /auth/users/{id} - Delete user (ADMIN only)
    @DeleteMapping("/{id}")
    public ResponseEntity<Void> deleteUser(@PathVariable Long id) {
        userManagementService.deleteUser(id);
        return ResponseEntity.noContent().build();
    }
}
