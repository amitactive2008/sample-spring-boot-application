import React, { useState } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import { FaEnvelope, FaLock, FaBug } from 'react-icons/fa';
import * as Yup from 'yup';
import BasicForm from '../../components/BasicForm';
import CustomTextField from '../../components/CustomTextField';
import CustomButton from '../../components/CustomButton';
import BasicAlertBox from '../../components/BasicAlertBox';
import { registerUser } from '../../api/auth';

const registerSchema = Yup.object().shape({
  email: Yup.string()
    .trim()
    .email('Invalid email')
    .max(254, 'Email is too long')
    .required('Email is required'),
  password: Yup.string()
    .required('Password is required')
    .min(8, 'Password must be at least 8 characters')
    .matches(/[a-z]/, 'Password must contain at least one lowercase letter')
    .matches(/[A-Z]/, 'Password must contain at least one uppercase letter')
    .matches(/[0-9]/, 'Password must contain at least one number')
    .matches(
      /[@$!%*?&\-_.#]/,
      'Password must contain at least one special character (@ $ ! % * ? & - _ . #)'
    ),
  confirmPassword: Yup.string()
    .oneOf([Yup.ref('password'), null], 'Passwords must match')
    .required('Confirm password is required'),
});

const RegisterPage = () => {
  const navigate = useNavigate();
  const [alert, setAlert] = useState({
    open: false,
    message: '',
    type: 'info',
    title: '',
  });

  const handleRegister = async (values, { setSubmitting }) => {
    try {
      await registerUser(values.email, values.password);

      setAlert({
        open: true,
        message: 'Account created successfully! Please login.',
        type: 'success',
        title: 'Registration Successful',
      });

      //  Keep loading until redirect (no setSubmitting(false) on success)
      setTimeout(() => {
        navigate('/login');
        // no need setSubmitting(false) because component unmounts after navigate
      }, 1500);
    } catch (error) {
      const msg =
        error.response?.data?.message ||
        error.response?.data?.error ||
        'Registration failed. Please try again.';

      setAlert({
        open: true,
        message: msg,
        type: 'danger',
        title: 'Registration Failed',
      });

      // ✅ Stop loading only on error so user can retry
      setSubmitting(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-gray-50 via-white to-gray-100 p-4 relative overflow-hidden">
      {/* Decorative blurred circles — viewport-scaled for consistent coverage */}
      <div className="absolute -top-[20%] -left-[10%] w-[60vw] h-[60vw] max-w-[900px] max-h-[900px] min-w-[400px] min-h-[400px] bg-[#3da58a]/30 rounded-full blur-[150px]" />
      <div className="absolute -bottom-[20%] -right-[10%] w-[55vw] h-[55vw] max-w-[850px] max-h-[850px] min-w-[350px] min-h-[350px] bg-[#1a365d]/25 rounded-full blur-[140px]" />
      <div className="absolute top-[20%] -right-[5%] w-[45vw] h-[45vw] max-w-[700px] max-h-[700px] min-w-[300px] min-h-[300px] bg-[#6366f1]/20 rounded-full blur-[130px]" />
      <div className="absolute bottom-[10%] left-[5%] w-[40vw] h-[40vw] max-w-[650px] max-h-[650px] min-w-[250px] min-h-[250px] bg-[#f59e0b]/15 rounded-full blur-[120px]" />

      <div className="w-full max-w-md relative z-10">
        {/* Logo */}
        <div className="text-center mb-8">
          <div className="inline-flex items-center justify-center w-16 h-16 bg-[#3da58a] rounded-2xl shadow-2xl mb-4">
            <FaBug className="h-8 w-8 text-white" />
          </div>
          <h1 className="text-3xl font-bold text-gray-900">Create Account</h1>
          <p className="text-gray-500 text-sm mt-1">Join the Issue Tracker platform</p>
        </div>

        {/* Glassmorphism Card */}
        <div className="bg-white/30 backdrop-blur-2xl border border-white/40 rounded-2xl p-8 shadow-2xl">
          <BasicForm
            initialValues={{ email: '', password: '', confirmPassword: '' }}
            validationSchema={registerSchema}
            onSubmit={handleRegister}
          >
            {({ errors, touched, handleChange, values, isSubmitting }) => (
              <>
                <CustomTextField
                  name="email"
                  label="Email Address"
                  type="email"
                  value={values.email}
                  onChange={handleChange}
                  error={errors.email}
                  touched={touched.email}
                  icon={FaEnvelope}
                />

                <CustomTextField
                  name="password"
                  label="Password"
                  type="password"
                  value={values.password}
                  onChange={handleChange}
                  error={errors.password}
                  touched={touched.password}
                  icon={FaLock}
                />

                <CustomTextField
                  name="confirmPassword"
                  label="Confirm Password"
                  type="password"
                  value={values.confirmPassword}
                  onChange={handleChange}
                  error={errors.confirmPassword}
                  touched={touched.confirmPassword}
                  icon={FaLock}
                />

                <CustomButton type="submit" disabled={isSubmitting}>
                  {isSubmitting ? 'Creating Account...' : 'Create Account'}
                </CustomButton>
              </>
            )}
          </BasicForm>

          <p className="text-center text-sm text-gray-500 mt-4">
            Already have an account?{' '}
            <Link to="/login" className="text-[#3da58a] font-semibold hover:underline">
              Sign In
            </Link>
          </p>
        </div>
      </div>

      <BasicAlertBox
        open={alert.open}
        title={alert.title}
        message={alert.message}
        type={alert.type}
        onConfirm={() => setAlert({ ...alert, open: false })}
        autoClose={alert.type === 'success'}
      />
    </div>
  );
};

export default RegisterPage;
