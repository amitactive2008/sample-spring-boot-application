package com.example.issue_service.dto;

import lombok.*;

import java.time.LocalDateTime;

@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class IssueStatusHistoryDTO {

    private Long id;
    private Long issueId;
    private String previousStatus;
    private String newStatus;
    private String changedBy;
    private LocalDateTime changedAt;
}
