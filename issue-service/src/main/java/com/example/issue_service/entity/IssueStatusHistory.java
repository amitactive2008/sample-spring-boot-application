package com.example.issue_service.entity;

import jakarta.persistence.*;
import lombok.*;

import java.time.LocalDateTime;

@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
@Entity
@Table(name = "issue_status_history")
public class IssueStatusHistory {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false)
    private Long issueId;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private IssueStatus previousStatus;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private IssueStatus newStatus;

    @Column(nullable = false)
    private String changedBy; // email of user who changed the status

    @Column(nullable = false)
    private LocalDateTime changedAt;

    @PrePersist
    protected void onCreate() {
        if (this.changedAt == null) {
            this.changedAt = LocalDateTime.now();
        }
    }
}
