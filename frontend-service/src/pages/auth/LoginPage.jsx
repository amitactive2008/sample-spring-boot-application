import React, { useState } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import { FaEnvelope, FaLock, FaBug } from 'react-icons/fa';
import * as Yup from 'yup';
import BasicForm from '../../components/BasicForm';
import CustomTextField from '../../components/CustomTextField';
import CustomButton from '../../components/CustomButton';
import BasicAlertBox from '../../components/BasicAlertBox';
import { loginUser, saveAuthData } from '../../api/auth';

const loginSchema = Yup.object().shape({
  email: Yup.string()
    .trim()
    .email('Invalid email')
    .max(254, 'Email is too long')
    .required('Email is required'),
  password: Yup.string()
    .required('Password is required')
    .min(4, 'Password must be at least 4 characters'),
});

const LoginPage = () => {
  const navigate = useNavigate();

  const [alert, setAlert] = useState({
    open: false,
    message: '',
    type: 'info',
    title: '',
  });

  const handleLogin = async (values, { setSubmitting }) => {
    try {
      const response = await loginUser(values.email, values.password);
      saveAuthData(response);

      setAlert({
        open: true,
        message: 'Login successful! Redirecting...',
        type: 'success',
        title: 'Welcome Back',
      });

      // ✅ Keep loading until navigation (no setSubmitting(false) on success)
      setTimeout(() => {
        const role = response.role;
        if (role === 'ADMIN') {
          navigate('/admin/users');
        } else {
          navigate('/issues/new');
        }
        // no need to setSubmitting(false) because component will unmount after navigate
      }, 800);
    } catch (error) {
      const msg =
        error.response?.data?.message ||
        error.response?.data?.error ||
        'Login failed. Please check your credentials.';

      setAlert({
        open: true,
        message: msg,
        type: 'danger',
        title: 'Login Failed',
      });

      //  Stop loading only on error so user can retry
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
          <h1 className="text-3xl font-bold text-gray-900">Issue Tracker</h1>
          <p className="text-gray-500 text-sm mt-1">Sign in to your account</p>
        </div>

        {/* Glassmorphism Card */}
        <div className="bg-white/30 backdrop-blur-2xl border border-white/40 rounded-2xl p-8 shadow-2xl">
          <BasicForm
            initialValues={{ email: '', password: '' }}
            validationSchema={loginSchema}
            onSubmit={handleLogin}
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

                <CustomButton type="submit" disabled={isSubmitting}>
                  {isSubmitting ? 'Signing in...' : 'Sign In'}
                </CustomButton>
              </>
            )}
          </BasicForm>

          <p className="text-center text-sm text-gray-500 mt-4">
            Don&apos;t have an account?{' '}
            <Link to="/register" className="text-[#3da58a] font-semibold hover:underline">
              Register
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

export default LoginPage;
