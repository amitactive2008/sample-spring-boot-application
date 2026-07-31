package com.example.auth_service.service;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.mail.SimpleMailMessage;
import org.springframework.mail.javamail.JavaMailSender;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Service;

@Slf4j
@Service
@RequiredArgsConstructor
public class EmailService {

    private final JavaMailSender mailSender;

    @Value("${mail.from}")
    private String from;

    @Value("${mail.enabled:false}")
    private boolean enabled;

    @Async
    public void sendWelcomeEmail(String toEmail) {
        if (!enabled) {
            log.debug("Mail disabled — skipping welcome email to {}", toEmail);
            return;
        }
        try {
            SimpleMailMessage message = new SimpleMailMessage();
            message.setFrom(from);
            message.setTo(toEmail);
            message.setSubject("Welcome to Issue Tracker!");
            message.setText(
                "Hello,\n\n" +
                "Welcome to Issue Tracker! Your account has been successfully created.\n\n" +
                "You can now log in and start tracking your issues.\n\n" +
                "Best regards,\n" +
                "The Issue Tracker Team"
            );
            mailSender.send(message);
            log.info("Welcome email sent to {}", toEmail);
        } catch (Exception e) {
            log.error("Failed to send welcome email to {}: {}", toEmail, e.getMessage());
        }
    }
}
