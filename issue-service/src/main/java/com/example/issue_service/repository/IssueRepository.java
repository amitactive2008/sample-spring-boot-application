package com.example.issue_service.repository;

import com.example.issue_service.entity.Issue;
import com.example.issue_service.entity.IssuePriority;
import com.example.issue_service.entity.IssueStatus;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

@Repository
public interface IssueRepository extends JpaRepository<Issue, Long> {

    // Count by status
    long countByStatus(IssueStatus status);

    // Search & filter with pagination
    @Query("SELECT i FROM Issue i WHERE " +
            "(:title IS NULL OR LOWER(i.title) LIKE LOWER(CONCAT('%', :title, '%'))) AND " +
            "(:status IS NULL OR i.status = :status) AND " +
            "(:priority IS NULL OR i.priority = :priority)")
    Page<Issue> searchAndFilter(
            @Param("title") String title,
            @Param("status") IssueStatus status,
            @Param("priority") IssuePriority priority,
            Pageable pageable
    );
}
