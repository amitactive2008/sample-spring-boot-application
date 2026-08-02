package com.example.issue_service.controller;

import com.example.issue_service.dto.*;
import com.example.issue_service.service.IssueService;
import com.example.issue_service.service.IssueStatusService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/issues")
@RequiredArgsConstructor
public class IssueController {

    private final IssueService issueService;
    private final IssueStatusService issueStatusService;

   
    // CREATE - POST /issues
   
    @PostMapping
    public ResponseEntity<IssueResponseDTO> create(@Valid @RequestBody IssueRequestDTO dto,
                                                    Authentication authentication) {
        String email = authentication.getName(); // email from JWT subject
        IssueResponseDTO response = issueService.createIssue(dto, email);
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }

   
    // GET ALL (paginated + search/filter) - GET /issues?title=&status=&priority=&page=0&size=10&sort=createdAt,desc
   
    @GetMapping
    public ResponseEntity<Page<IssueResponseDTO>> getAll(
            @RequestParam(required = false) String title,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String priority,
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "10") int size,
            @RequestParam(defaultValue = "createdAt,desc") String sort) {

        String[] sortParts = sort.split(",");
        Sort.Direction direction = sortParts.length > 1 && sortParts[1].equalsIgnoreCase("asc")
                ? Sort.Direction.ASC : Sort.Direction.DESC;
        Pageable pageable = PageRequest.of(page, size, Sort.by(direction, sortParts[0]));

        Page<IssueResponseDTO> result = issueService.getAllIssues(title, status, priority, pageable);
        return ResponseEntity.ok(result);
    }

   
    // GET BY ID - GET /issues/{id}
   
    @GetMapping("/{id}")
    public ResponseEntity<IssueResponseDTO> getById(@PathVariable Long id) {
        return ResponseEntity.ok(issueService.getById(id));
    }

   
    // COUNT BY STATUS - GET /issues/count-by-status
   
    @GetMapping("/count-by-status")
    public ResponseEntity<IssueCountByStatusDTO> getCountByStatus() {
        return ResponseEntity.ok(issueService.getCountByStatus());
    }

   
    // UPDATE - PUT /issues/{id}
   
    @PutMapping("/{id}")
    public ResponseEntity<IssueResponseDTO> update(@PathVariable Long id,
                                                    @Valid @RequestBody IssueRequestDTO dto) {
        return ResponseEntity.ok(issueService.updateIssue(id, dto));
    }

   
    // UPDATE STATUS - PATCH /issues/{id}/status
   
    @PatchMapping("/{id}/status")
    public ResponseEntity<IssueResponseDTO> updateStatus(@PathVariable Long id,
                                                          @RequestBody IssueStatusUpdateDTO dto,
                                                          Authentication authentication) {
        String email = authentication.getName();
        return ResponseEntity.ok(issueStatusService.updateStatus(id, dto, email));
    }

   
    // GET STATUS HISTORY - GET /issues/{id}/history
   
    @GetMapping("/{id}/history")
    public ResponseEntity<List<IssueStatusHistoryDTO>> getStatusHistory(@PathVariable Long id) {
        return ResponseEntity.ok(issueStatusService.getStatusHistory(id));
    }

   
    // DELETE - DELETE /issues/{id} (ADMIN only)
   
    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable Long id) {
        issueService.deleteIssue(id);
        return ResponseEntity.noContent().build();
    }
}
