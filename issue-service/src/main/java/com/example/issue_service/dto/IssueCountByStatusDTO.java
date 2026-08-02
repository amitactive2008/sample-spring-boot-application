package com.example.issue_service.dto;

import lombok.*;

import java.util.Map;

@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class IssueCountByStatusDTO {

    private long total;
    private Map<String, Long> countByStatus;
    // e.g. { "OPEN": 5, "IN_PROGRESS": 3, "RESOLVED": 10, "CLOSED": 2 }
}
