package com.example.issue_service.dto;

import lombok.*;

import java.time.LocalDateTime;

@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class IssueResponseDTO {

    private Long id;
    private String title;
    private String description;
    private String status;       // OPEN, IN_PROGRESS, RESOLVED, CLOSED
    private String severity;     // LOW, MEDIUM, HIGH, CRITICAL
    private String priority;     // LOW, MEDIUM, HIGH, URGENT
    private String createdBy;
    private LocalDateTime createdAt;
    private LocalDateTime updatedAt;
}
