package com.example.issue_service.dto;

import jakarta.validation.constraints.NotBlank;
import lombok.*;

@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class IssueRequestDTO {

    @NotBlank(message = "Title is required")
    private String title;

    private String description;

    private String severity;  // LOW, MEDIUM, HIGH, CRITICAL (defaults to MEDIUM)

    private String priority;  // LOW, MEDIUM, HIGH, URGENT (defaults to MEDIUM)
}
