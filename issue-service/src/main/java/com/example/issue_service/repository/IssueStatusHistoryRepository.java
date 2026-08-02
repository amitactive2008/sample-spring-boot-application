package com.example.issue_service.repository;

import com.example.issue_service.entity.IssueStatusHistory;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface IssueStatusHistoryRepository extends JpaRepository<IssueStatusHistory, Long> {

    List<IssueStatusHistory> findByIssueIdOrderByChangedAtDesc(Long issueId);
}
