package com.example.issue_service.dto;

import lombok.*;

@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class IssueStatusUpdateDTO {

    private String status; // OPEN, IN_PROGRESS, RESOLVED, CLOSED
}
