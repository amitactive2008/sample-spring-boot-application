package com.example.auth_service;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.mail.javamail.JavaMailSender;
import org.springframework.mail.javamail.JavaMailSenderImpl;
import org.springframework.test.context.ActiveProfiles;

@SpringBootTest
@ActiveProfiles("test")
@Import(AuthServiceApplicationTests.MailTestConfig.class)
class AuthServiceApplicationTests {

	@TestConfiguration
	static class MailTestConfig {

		@Bean
		JavaMailSender javaMailSender() {
			return new JavaMailSenderImpl();
		}
	}

	@Test
	void contextLoads() {
	}
}
