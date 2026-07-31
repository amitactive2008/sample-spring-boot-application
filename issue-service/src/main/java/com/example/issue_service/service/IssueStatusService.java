package com.example.issue_service.service;

import com.example.issue_service.dto.IssueResponseDTO;
import com.example.issue_service.dto.IssueStatusHistoryDTO;
import com.example.issue_service.dto.IssueStatusUpdateDTO;
import com.example.issue_service.entity.Issue;
import com.example.issue_service.entity.IssueStatus;
import com.example.issue_service.entity.IssueStatusHistory;
import com.example.issue_service.exception.InvalidStatusTransitionException;
import com.example.issue_service.exception.IssueNotFoundException;
import com.example.issue_service.repository.IssueRepository;
import com.example.issue_service.repository.IssueStatusHistoryRepository;
import lombok.RequiredArgsConstructor;
import org.modelmapper.ModelMapper;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.stream.Collectors;

@Service
@RequiredArgsConstructor
public class IssueStatusService {

    private final IssueRepository issueRepository;
    private final IssueStatusHistoryRepository statusHistoryRepository;
    private final ModelMapper modelMapper;

   
    // UPDATE STATUS
   
    @Transactional
    public IssueResponseDTO updateStatus(Long id, IssueStatusUpdateDTO dto, String changedByEmail) {
        Issue existing = issueRepository.findById(id)
                .orElseThrow(() -> new IssueNotFoundException("Issue not found with id: " + id));

        IssueStatus newStatus;
        try {
            newStatus = IssueStatus.valueOf(dto.getStatus().toUpperCase());
        } catch (IllegalArgumentException | NullPointerException e) {
            throw new InvalidStatusTransitionException("Invalid status: " + dto.getStatus());
        }

        IssueStatus previousStatus = existing.getStatus();

        // Record status change history
        IssueStatusHistory history = IssueStatusHistory.builder()
                .issueId(existing.getId())
                .previousStatus(previousStatus)
                .newStatus(newStatus)
                .changedBy(changedByEmail)
                .build();
        statusHistoryRepository.save(history);

        existing.setStatus(newStatus);
        Issue saved = issueRepository.save(existing);
        IssueResponseDTO response = modelMapper.map(saved, IssueResponseDTO.class);
        return response;
    }

   
    // GET STATUS HISTORY
   
    public List<IssueStatusHistoryDTO> getStatusHistory(Long id) {
        // Verify issue exists
        issueRepository.findById(id)
                .orElseThrow(() -> new IssueNotFoundException("Issue not found with id: " + id));

        return statusHistoryRepository.findByIssueIdOrderByChangedAtDesc(id)
                .stream()
                .map(this::mapToHistoryDTO)
                .collect(Collectors.toList());
    }

    private IssueStatusHistoryDTO mapToHistoryDTO(IssueStatusHistory history) {
        return modelMapper.map(history, IssueStatusHistoryDTO.class);
    }
}
