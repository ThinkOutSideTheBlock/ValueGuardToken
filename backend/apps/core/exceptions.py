from rest_framework.exceptions import APIException


class CustomAPIException(APIException):
    """Example of a custom exception"""
    status_code = 400
    default_detail = "Something went wrong"
    default_code = "custom_error"
