import React from 'react';
import { Formik, Form } from 'formik';

const BasicForm = ({
  initialValues,
  validationSchema,
  validate,
  onSubmit,
  children,
  enableReinitialize = false,
}) => {
  return (
    <Formik
      initialValues={initialValues}
      validationSchema={validationSchema}
      validate={validate}
      onSubmit={onSubmit}
      validateOnChange={true}
      validateOnBlur={true}
      enableReinitialize={enableReinitialize}
    >
      {({ errors, touched, handleChange, values, setFieldValue, isSubmitting }) => (
        <Form className='flex flex-col w-full space-y-4'>
          {children({ errors, touched, handleChange, values, setFieldValue, isSubmitting })}
        </Form>
      )}
    </Formik>
  );
};

export default BasicForm;
