package com.example.issue_service.service;

import com.example.issue_service.dto.IssueCountByStatusDTO;
import com.example.issue_service.dto.IssueRequestDTO;
import com.example.issue_service.dto.IssueResponseDTO;
import com.example.issue_service.entity.Issue;
import com.example.issue_service.entity.IssuePriority;
import com.example.issue_service.entity.IssueSeverity;
import com.example.issue_service.entity.IssueStatus;
import com.example.issue_service.exception.IssueNotFoundException;
import com.example.issue_service.repository.IssueRepository;
import lombok.RequiredArgsConstructor;
import org.modelmapper.ModelMapper;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.stereotype.Service;

import java.util.LinkedHashMap;
import java.util.Map;

@Service
@RequiredArgsConstructor
public class IssueService {

    private final IssueRepository issueRepository;
    private final ModelMapper modelMapper;

   
    // CREATE
   
    public IssueResponseDTO createIssue(IssueRequestDTO dto, String createdByEmail) {
        Issue issue = modelMapper.map(dto, Issue.class);
        issue.setStatus(IssueStatus.OPEN);
        issue.setSeverity(parseSeverity(dto.getSeverity()));
        issue.setPriority(parsePriority(dto.getPriority()));
        issue.setCreatedBy(createdByEmail);

        Issue saved = issueRepository.save(issue);
        IssueResponseDTO response = mapToResponse(saved);
        return response;
    }

   
    // GET ALL (paginated + search/filter)
   
    public Page<IssueResponseDTO> getAllIssues(String title, String status, String priority, Pageable pageable) {
        IssueStatus issueStatus = null;
        IssuePriority issuePriority = null;

        if (status != null && !status.isBlank()) {
            try {
                issueStatus = IssueStatus.valueOf(status.toUpperCase());
            } catch (IllegalArgumentException e) {
                throw new IllegalArgumentException("Invalid status: " + status);
            }
        }

        if (priority != null && !priority.isBlank()) {
            try {
                issuePriority = IssuePriority.valueOf(priority.toUpperCase());
            } catch (IllegalArgumentException e) {
                throw new IllegalArgumentException("Invalid priority: " + priority);
            }
        }

        String searchTitle = (title != null && !title.isBlank()) ? title : null;

        Page<Issue> issues = issueRepository.searchAndFilter(searchTitle, issueStatus, issuePriority, pageable);
        return issues.map(this::mapToResponse);
    }

   
    // GET BY ID
   
    public IssueResponseDTO getById(Long id) {
        Issue issue = issueRepository.findById(id)
                .orElseThrow(() -> new IssueNotFoundException("Issue not found with id: " + id));
        return mapToResponse(issue);
    }

   
    // COUNT BY STATUS
   
    public IssueCountByStatusDTO getCountByStatus() {
        Map<String, Long> countMap = new LinkedHashMap<>();
        long total = 0;

        for (IssueStatus s : IssueStatus.values()) {
            long count = issueRepository.countByStatus(s);
            countMap.put(s.name(), count);
            total += count;
        }

        return IssueCountByStatusDTO.builder()
                .total(total)
                .countByStatus(countMap)
                .build();
    }

   
    // UPDATE
   
    public IssueResponseDTO updateIssue(Long id, IssueRequestDTO dto) {
        Issue existing = issueRepository.findById(id)
                .orElseThrow(() -> new IssueNotFoundException("Issue not found with id: " + id));

        modelMapper.map(dto, existing);
        existing.setSeverity(parseSeverity(dto.getSeverity()));
        existing.setPriority(parsePriority(dto.getPriority()));

        Issue saved = issueRepository.save(existing);
        IssueResponseDTO response = mapToResponse(saved);
        return response;
    }

   
    // DELETE (ADMIN only - handled in SecurityConfig)
   
    public void deleteIssue(Long id) {
        Issue existing = issueRepository.findById(id)
                .orElseThrow(() -> new IssueNotFoundException("Issue not found with id: " + id));
        issueRepository.delete(existing);
    }

   
    // HELPER METHODS
   
    private IssueResponseDTO mapToResponse(Issue issue) {
        return modelMapper.map(issue, IssueResponseDTO.class);
    }

    private IssueSeverity parseSeverity(String severity) {
        if (severity == null || severity.isBlank()) return IssueSeverity.MEDIUM;
        try {
            return IssueSeverity.valueOf(severity.toUpperCase());
        } catch (IllegalArgumentException e) {
            return IssueSeverity.MEDIUM;
        }
    }

    private IssuePriority parsePriority(String priority) {
        if (priority == null || priority.isBlank()) return IssuePriority.MEDIUM;
        try {
            return IssuePriority.valueOf(priority.toUpperCase());
        } catch (IllegalArgumentException e) {
            return IssuePriority.MEDIUM;
        }
    }
}
